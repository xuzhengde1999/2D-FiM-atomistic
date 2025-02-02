% 2D atomistic model for FiM
% require nvidia GPU
clear all;clc;close all;tic
%% control parameter
constantfile;
clear gam
rk4=1;%1:rk4,0:heun Method,2:4th predictor-corrector
bc=1;%0.periodic condition;1,not periodic
DMIenable=1;
dwcalc=1;%1:simulate dw motion 0: no domain wall
thermalenable=0;%enable thermal field?
%% load magnetization
loadstartm=1;%1:load magnetization file; 0:direct calculate
if loadstartm
startmname='startm_20x250.mat';
end
%% use fixed atom distribution
load_fixed_atom_distrib=1;%load fixed atom distribution
save_fixed_atom_distrib=0;%save fixed atom distribution
if save_fixed_atom_distrib && load_fixed_atom_distrib
   error('only one of load_fixed_atom_distrib or save_fixed_atom_distrib can be enabled'); 
end
if load_fixed_atom_distrib
    display('use fixed atom distribution')
elseif save_fixed_atom_distrib
    display('save fixed atom distribution')
else
   display('use random atom distribution')
   rng('shuffle');
end
%% enable dipole
dipolemode=0;
%0:not calcualte dipole, 1: direct calculation using CPU
%2:direct calculation using CPU, 3:calculation using macrocell
if dipolemode==3
    natom_mc_W=2;%number of atoms in the macrocell along x direction
    natom_mc_L=2;%number of atoms in the macrocell along y direction
end
%% fix atoms at the edge
enablefixedge=0;%fix the atoms at the edge
if enablefixedge
    fixededgeL=3;%No of atoms fixed along Length
    mxleft=0;
    myleft=0;
    mzleft=1;
    mxright=0;
    myright=0;
    mzright=-1;  
end

%% optional control
%gpuDevice(1)%select GPU device
%% system generation
natomW=20;natomL=250;%no. of cells along vertical and horizontal direction, 
%note this is different to the x,y,z in h_ex or hdmi etc
compositionn=0.1;%composition percentage (X) of RE element, e.g. GdX(FeCo)1-X
d=0.4e-9;%[m],lattice constant
natom=natomW*natomL;
systemgeneration();
%% FiM parameters
Ksim=0.4e-3*ele;
%or 0.807246e-23;%[J], easy-axis anisotropy, 2011-nature-I. Radu, 
% this value is questionable
%Renjie and Zhengde for pointing out that 0.4e-3*ele is too large.
Jgdgd=-1.26e-21;Jfefe=-2.835e-21;Jfegd=1.09e-21;%[J/link], 2011-nature-I. Radu
gTM=2.2;gRE=2;%g-factor
gamTM=gTM*mub/(hbar*ele);%1/(s.T)refer to "PRL 97, 217202 (2006), Jiang Xin"
gamRE=gRE*mub/(hbar*ele);
tz=d;%[m],thickness of FiM
musRE=7.63*mub;musTM=2.217*mub;%[J/T]magnetic moment [1]
msRE=musRE/d^3;%[A/m], saturation magnetization
msTM=musTM/d^3;
if DMIenable
    Dsim=128e-6*ele;%[J], DMI
else
    Dsim=0;
end
alp=0.02;%Gilbert damping
%% electrical parameters
jcSOT=1e9;%[A/m2]
jcSTT=1.5e9;%[A/m2]
Hext=[0,0,0e-3];% corresponding to runtime2
%% SOT parameters
SOT_DLT=0;%1(0),enable(disable) SOT damping torque
SOT_FLT=0;%1(0),enable(disable) SOT field-like torque
psjSHE=[0,1,0];%spin flux polarization
psjSHEx=psjSHE(1);
psjSHEy=psjSHE(2);
psjSHEz=psjSHE(3);
thetaSH=0.2;%spin hall angle
if SOT_FLT
    chi=0;%ratio of FLT/DLT
else
    chi=0;
end
BDSOTRE=SOT_DLT*hbar/2*thetaSH*jcSOT/(msRE*tz);%[T]
BDSOTTM=SOT_DLT*hbar/2*thetaSH*jcSOT/(msTM*tz);
%% STT parameters
STT_DLT=0;%1(0),enable(disable) SOT damping torque
STT_FLT=0;%1(0),enable(disable) SOT field-like torque
psjSTT=[0,0,1];%spin flux polarization
psjSTTx=psjSTT(1);
psjSTTy=psjSTT(2);
psjSTTz=psjSTT(3);
etaSTT=0.8;%spin hall angle
if STT_FLT
    chiSTT=0;%ratio of FLT/DLT
else
    chiSTT=0;
end
BDSTTRE=STT_DLT*hbar/2*etaSTT*jcSTT/(msRE*tz);%[T]
BDSTTTM=STT_DLT*hbar/2*etaSTT*jcSTT/(msTM*tz);
%% other parameters
T=100;%[K]
%% time control
gpusave=1e-12;%how often saving gpu data
gpurun_number=3;
tstep=2e-16;
savetstep=100;%this is used to reduce data size

gpusteps=round(gpusave/tstep);
runtime=gpurun_number*gpusave;%second run for dw motion
totstep=round(runtime/tstep);
t=linspace(tstep,runtime,totstep);%This need to be optimized

if ~mod(gpusteps,savetstep)==0
    error('gpusteps should be multiple integer times of savetstep, otherwise there might be errors')
end

tmp1=ones(1,gpusteps);
tmp2=tmp1(1:savetstep:end);
final_m_savestep=size(tmp2,2);
clear tmp1 tmp2

if (SOT_DLT || SOT_FLT) && ~(rk4==1)
    error('only rk4 is implemented for spin torque driven')
end

if(0)%view initial state
    gridW = 1:natomW;
    gridL = 1:natomL;
    [gridplotx,gridploty] = meshgrid(gridL,gridW);
    gridz=zeros(natomW,natomL);
    figure;hold on%initial magnetization
    for ctL=1:natomL
        for ctW=1:natomW
            if atomtype_(ctW,ctL)==0%TM
                quiver3(gridplotx(natomW-ctW+1,ctL),gridploty(natomW-ctW+1,ctL),gridz(ctW,ctL),...
                    mx_init(ctW,ctL),my_init(ctW,ctL),mz_init(ctW,ctL),'r');
            else
                quiver3(gridplotx(natomW-ctW+1,ctL),gridploty(natomW-ctW+1,ctL),gridz(ctW,ctL),...
                    mx_init(ctW,ctL),my_init(ctW,ctL),mz_init(ctW,ctL),'b');
            end
        end
    end
end
%% dynamic calc
integrate_llg(); toc
%% save data
save('finalnew.mat')






