%% Feature tracking example
%   
% This is a complete example of feature tracking on Engabreen.
% 
% # Load images & data
% # Use GCPs to determine camera view direction and lens distortion
%   parameters of image A.
% # track stable rock features to determine camera shake and infer view direction
%   of image B
% # Pre-process DEM by filling crevasses.
% # Track ice motion between images
% # Georeference tracked points and calculate real world velocities.
%
%
close all

%% Setup file locations and load images & data
%
% 

idA=8902; idB=8937; % image ids (/file numbers)

imagefolder='data';
fA=fullfile(imagefolder,sprintf('IMG_%4.0f.jpg',idA));
fB=fullfile(imagefolder,sprintf('IMG_%4.0f.jpg',idB));

%load images:
A=imread(fA);
B=imread(fB);


dem=load(fullfile('data','dem')); %load DEM
gcpA=load(fullfile('data','gcp8902.txt'));%load ground control points for image A

photodates=load(fullfile('data','photodates.mat'));
tA=interp1(photodates.id,photodates.t,idA); %time of image A
tB=interp1(photodates.id,photodates.t,idB); %time of image B

%% Determine camera parameters for image A
%
% # Initial crude guess at camera parameters
% # Use GCPs to optimize camera parameters
% 
FocalLength=30; %mm
SensorSize=[22.0 14.8]; %mm
imgsz=size(A);
f=imgsz([2 1]).*(FocalLength./SensorSize); 

%known camera location: 
cameralocation=[446722.0 7396671.0 770.0]; 

%crude estimate of look direction.
camA=camera(cameralocation,size(A),[200 0 0]*pi/180,f); %loooking west

%Use GCPs to optimize the following camera parameters:
%view dir, focal lengths, and a simple radial distortion model
[camA,rmse,aic]=camA.optimizecam(gcpA(:,1:3),gcpA(:,4:5),'00000111110010000000');
fprintf('reprojectionerror=%3.1fpx  AIC:%4.0f\n',rmse,aic) 


%Visually compare the projection of the GCPs with the pixel coords:
figure
image(A)
axis equal off
hold on
uv=camA.project(gcpA(:,1:3));
plot(gcpA(:,4),gcpA(:,5),'+',uv(:,1),uv(:,2),'rx')
legend('UV of GCP','projection of GCPs')
title(sprintf('Projection of ground control points. RMSE=%.1fpx',rmse))


%% Determine view direction of camera B.
%
% # find movement of rock features between images A and B
% # determine camera B by pertubing viewdir of camera A. 


%First get an approximate estimate of the image shift using a single large
%template
points=[3000, 995];
[xyo,C]=templatematch(A,B,points,200,260,0.5,[0 0],false,'PC') 

%Get a whole bunch of image shift estimates using a grid of probe points.
%having multiple shift estimates will allow us to determine camera
%rotation.
[pX,pY]=meshgrid(200:700:4000,100:400:1000);
points=round([pX(:) pY(:)+pX(:)/10]); 
[dxy,C]=templatematch(A,B,points,30,40,3,xyo,[idA idB]);


%Determine camera rotation between A and B from the set of image
%shifts.

%find 3d coords consistent with the 2d pixel coords in points.
xyz=camA.invproject(points);
%the projection of xyz has to match the shifted coords in points+dxy:
camB=camA.optimizecam(xyz,points+dxy,'00000111000000000000'); %optimize 3 view direction angles to determine camera B. 

%quantify the shift between A and B in terms of an angle. 
DeltaViewDirection=(camB.viewdir-camA.viewdir)*180/pi 


%% Prepare DEM by filling crevasses.
%
%
% The matches between images are often visual features such as
% the sharp contrast between the ice surface and shadow in a
% crevasse. The visual edge of such features are located on the crevasse
% tops and we use a smooth dem surface tracking through the crevasse tops
% when mapping feature pixel coordinates to world coordinates. 
%

% first pick a 2d-filtering routine depending on whether the image processing
% toolbox is present. 
if exist('imfilter','file')>1
    filterfun=@(f,A)imfilter(A,f,'replicate','same'); %this treats edges better.
else
    filterfun=@(f,A)filter2(f,A); 
end


%Apply a local averaging smooth to the DEM:
%large crevasses are ~40m wide. The filter has to be wide enough to bridge
%crevasses.
sigma=10; %dem-pixels 
fs=fspecial('gaussian',[3 3]*sigma,sigma);
dem.smoothed=filterfun(fs,dem.Z);

% Apply an extreme weighting local smooth to the deviation between the
% sZ and Zmask (extract tops of crevasses):
fs=fspecial('disk',round(sigma*1));
extremeweight=1.1;
dem.filled=log(filterfun(fs,exp((dem.Z-dem.smoothed)*extremeweight)))/extremeweight;

%apply a post-smoothing to the jagged crevasse tops.
fs=fspecial('gaussian',[3 3]*sigma,sigma);%fs=fs/sum(fs(:));%
dem.filled=filterfun(fs,dem.filled);
dem.filled=dem.filled+dem.smoothed;

%Add back non-glaciated areas to the crevasse filled surface. 
dem.filled(~dem.mask)=dem.Z(~dem.mask);

%show a slice through the Original and crevasse filled DEM 
%Plots like these help choose an appropriate filter sizes. 
figure
plot(dem.x,dem.filled(400,:),dem.x,dem.Z(400,:),dem.x,dem.smoothed(400,:))
legend('crevasse filled','original','smoothed','location','best')
title('Slice through crevasse filled dem.')


%% Viewshed from camera
% The viewshed is all the points of the dem that are visible from the
% camera location. They may not be in the field of view of the lens. 
dem.visible=voxelviewshed(dem.X,dem.Y,dem.filled,camA.xyz);

%show the viewshed by shading the dem.rgb image.
figure
title('Viewshed of DEM (i.e. potentially visible from camera location)')
image(dem.x,dem.y,bsxfun(@times,im2double(dem.rgb),(0.3+0.7*dem.visible)))
axis equal xy off
hold on
plot(camA.xyz(1),camA.xyz(2),'r+')

%% Generate a set of points to be tracked between images
%
% # Generate a regular grid of candidate points in world coordinates.
% # Cull the set of candidate points to those that are visible and
% glaciated 
%
%

[X,Y]=meshgrid(min(dem.x):50:max(dem.x),min(dem.y):50:max(dem.y));%make a 50m grid
keepers=double(dem.visible&dem.mask); %visible & glaciated dem points 
keepers=filter2(fspecial('disk',11),keepers); %throw away points close to the edge of visibility 
keepers=interp2(dem.X,dem.Y,keepers,X(:),Y(:))>.99; %which candidate points fullfill the criteria.
xyzA=[X(keepers) Y(keepers) interp2(dem.X,dem.Y,dem.filled,X(keepers),Y(keepers))];
[uvA,~,inframe]=camA.project(xyzA); %where would the candidate points be in image A
xyzA=xyzA(inframe,:); %cull points outside the camera field of view.
uvA=round(uvA(inframe,:)); %round because template match only works with integer pixel coords
uvA(end+1,:)=[2275 1342]; %add a non-glaciated point to test for residual camera movement (tunnel)
%Note xyzA no longer corresponds exactly to uvA because of the rounding.


%% Track points between images.

% calculate where points would be in image B if no ice motion.
% ( i.e. accounting only for camera shake)
camshake=camB.project(camA.invproject(uvA))-uvA;

showprogress=[idA idB];
wsearch=40; 
wtemplate=10;
super=5; %supersample the input images

[dxy,C]=templatematch(A,B,uvA,wtemplate,wsearch,super,camshake,showprogress,'myNCC'); %myNCC is faster than NCC in my tests

uvB=uvA+dxy;
signal2noise=C(:,1)./C(:,2);

%% Georeference tracked points
% ... and calculate velocities
xyzA=camA.invproject(uvA,dem.X,dem.Y,dem.filled); %has to be recalculated because uvA has been rounded.
xyzB=camB.invproject(uvB,dem.X,dem.Y,dem.filled-dem.mask*22.75*(tB-tA)/365); %impose a thinning of the DEM of 20m/yr between images.
V=(xyzB-xyzA)./(tB-tA); % 3d velocity.


%plot candidate points on map view
figure;
image(dem.x,dem.y,dem.rgb)
axis equal xy off tight
hold on
Vn=sqrt(sum(V.^2,2));
keep=signal2noise>2&C(:,1)>.8;
scatter(xyzA(keep,1),xyzA(keep,2),100,Vn(keep),'.')
quiver(xyzA(keep,1),xyzA(keep,2),V(keep,1)./Vn(keep),V(keep,2)./Vn(keep),.2,'k')
caxis([0 1])
colormap jet
colorbar('southoutside','limits',caxis)
plot(camA.xyz(1),camA.xyz(2),'r+')
title('Velocity in metres per day')



%project velocity onto downhill slope direction

[gradX,gradY]=gradient(dem.smoothed,dem.X(2,2)-dem.X(1,1),dem.Y(2,2)-dem.Y(1,1));
gradN=sqrt(gradX.^2+gradY.^2);
gradX=-gradX./gradN;gradY=-gradY./gradN;
gradX=interp2(dem.X,dem.Y,gradX,xyzA(:,1),xyzA(:,2));
gradY=interp2(dem.X,dem.Y,gradY,xyzA(:,1),xyzA(:,2));
Vgn=V(:,1).*gradX+V(:,2).*gradY;
Vg=[Vgn.*gradX Vgn.*gradY];

%     da=mod(atan2(V(:,2),V(:,1))-atan2(gradY,gradX)+pi,2*pi)-pi;
%     [jj median(da(keep)*180/pi)]
% end

figure
image(dem.x,dem.y,dem.rgb)
axis equal xy off tight
colormap jet

hold on
scatter(xyzA(keep,1),xyzA(keep,2),100,sqrt(sum(Vg(keep).^2,2)),'.')
quiver(xyzA(keep,1),xyzA(keep,2),Vg(keep,1)./Vgn(keep),Vg(keep,2)./Vgn(keep),.2,'k')
quiver(xyzA(keep,1),xyzA(keep,2),V(keep,1)./Vn(keep),V(keep,2)./Vn(keep),.2,'k','color',[.5 .5 .5])



caxis([0 1])

colorbar('southoutside','limits',caxis)

plot(camA.xyz(1),camA.xyz(2),'r+')
title('Velocity along slope direction in metres per day')
