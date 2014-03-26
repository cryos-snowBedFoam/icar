! simple PBL diffusion package for the Simple Weather Model
!  Local-K diffusion type PBL as in Louis (1979) as documented in Hong and Pan (1996) = HP96
!  Hong and Pan used this for their free atmosphere diffusion, but noted differences
!  used in the "current operational model" notably the asymptotic length scale lambda 
!
! HP96 = Hong,S.-Y. and H.-L. Pan (1996) Monthly Weather Review v127 p2322
! 		 Nonlocal Boundary Layer Vertical Diffusion in a Medium Range Forecast Model
! 
! Implemented with K,shear,stability... on half levels
! 	rho on half levels for f=k*rho*dq/dz*dt
! 	rho on full levels for q=q+f/rho
!   q,U,V on full levels
module pbl_simple
	use data_structures
	private
	public :: simple_pbl, finalize_simple_pbl, init_simple_pbl
	
! 	NOTE *_m indicates module level variables
! 	these variables are declared as module level variables so that they do not need to be allocated
!   deallocated, and re-allocated all the time. 

! 	gradient in the virtual potential temperature
	real, allocatable, dimension(:,:,:) :: virt_pot_temp_zgradient_m
! 	gradient in the richardson number
	real, allocatable, dimension(:,:,:) :: rig_m
! 	vertical wind shear (dwind / dz)
	real, allocatable, dimension(:,:,:) :: shear_m
! 	atmospheric stability
	real, allocatable, dimension(:,:,:) :: stability_m
! 	length scale that asymptotes from kappa*z to l0 (250m below)
	real, allocatable, dimension(:,:,:) :: l_m
! 	diffusion term for momentum
	real, allocatable, dimension(:,:,:) :: K_m
! 	diffusion term for scalars (K/prandtl)
	real, allocatable, dimension(:,:,:) :: Kq_m
! 	prandtl number to convert K for momentum to K for scalars
	real, allocatable, dimension(:,:,:) :: prandtl_m
	integer :: nx,nz,ny !NOTE these are subset from full domain e.g. nx-2,ny-2,nz-1
	
!	limits on Pr noted in HP96 page 2325 below eqn 13
	real, parameter :: pr_upper_limit = 4.0 !Prandtl number for stability
	real, parameter :: pr_lower_limit = 0.25 !Prandtl number for stability
	real, parameter :: asymp_length_scale = 1/250.0 !m from Hong and Pan (1996)
	real, parameter :: kappa =0.4 !von Karman constant
	! note, they actually use 30m because they only use this for free-atmosphere mixing
	! but they note that 250m is used in the operational model for the full PBL mixing
	
	
contains
	subroutine simple_pbl(domain,dt)
		type(domain_type), intent(inout) :: domain
		real, intent(in)::dt
		integer :: i,j,k
		
!       OpenMP parallelization small static chunk size because we typically get a small area that takes most of the time (because of substepping)
		!$omp parallel shared(domain,l_m,K_m,Kq_m,stability_m,prandtl_m,virt_pot_temp_zgradient_m,rig_m,shear_m) &
		!$omp firstprivate(nx,nz,ny,dt) private(i,k,j)
		!$omp do schedule(static, 2)
		do j=1,ny
			call calc_shear(domain,j)
			call calc_virt_pot_temp_zgradient(domain,j)
			call calc_richardson_gradient(domain,j)
			call calc_pbl_stability_function(j)
			
! 			from eqn 12 in HP96
			do k=1,nz
				l_m(:,k,j) = 1 / (1/(kappa*(domain%z(2:nx+1,k,j+1)-domain%terrain(2:nx+1,j+1))) + asymp_length_scale)
			enddo
! 			diffusion for momentum... can I ignore this term and go directly to scalars (to save memory)? 
! 			from HP96 eqn 11
!           k = l**2 * stability * shear * dt/dz
			K_m(:,:,j) = l_m(:,:,j)**2 * stability_m(:,:,j) * shear_m(:,:,j)
! 			diffusion for scalars
			Kq_m(:,:,j)=K_m(:,:,j)/prandtl_m(:,:,j)
! 			enforce limits specified in HP96
			do k=1,nz
				do i=1,nx
					if (Kq_m(i,k,j)>1000) then
						Kq_m(i,k,j)=1000
					elseif (Kq_m(i,k,j)<1) then
						Kq_m(i,k,j)=1
					endif
				enddo
			enddo
			Kq_m(:,:,j)= Kq_m(:,:,j)* dt/((domain%dz(2:nx+1,2:,j+1)+domain%dz(2:nx+1,:nz-1,j+1))/2)
			call pbl_diffusion(domain,j)
		enddo
		!$omp end do
		!$omp end parallel
		
	end subroutine simple_pbl
	
	subroutine diffuse_variable(q,rhomean,rho_dz,j)
		real, intent(inout),dimension(nx+2,nz+1,ny+2) :: q
		real, intent(in),dimension(nx,nz) :: rhomean,rho_dz
		integer,intent(in) :: j
		real,dimension(nx,nz)::fluxes
		
! 		Eventually this should be made into an implicit solution to avoid substepping
		! if gradient is downward (qv[z+1]>qv[z]) then flux is negative
		fluxes=Kq_m(:,:,j)*rhomean*(q(2:nx+1,:nz,j+1)-q(2:nx+1,2:,j+1))
		! first layer assumes no flow through the surface, that comes from the LSM
		q(2:nx+1,1,j+1)    = q(2:nx+1,1,j+1)    - fluxes(:,1) / rho_dz(:,1)
		! middle layers (no change for top layer assuming flux in = flux out)
		q(2:nx+1,2:nz,j+1) = q(2:nx+1,2:nz,j+1) - (fluxes(:,2:nz)-fluxes(:,:nz-1)) / rho_dz(:,2:nz)
		
	end subroutine diffuse_variable
	
	subroutine pbl_diffusion(domain,j)
		type(domain_type), intent(inout) :: domain
		integer,intent(in) :: j
		integer::i,nsubsteps,t
		real,dimension(nx,nz):: fluxes,rhomean,rho_dz
		
		rhomean=(domain%rho(2:nx+1,1:nz,j+1)+domain%rho(2:nx+1,2:,j+1))/2
		rho_dz=domain%dz(2:nx+1,2:nz,j+1)*domain%rho(2:nx+1,2:nz,j+1)
		
		! note Kq_m already has dt/dz embedded in it
		! diffusion fluxes within the PBL
		! q = q + (k dq/dz)/dz *dt
		
		!if K >1 we are in violation of the CFL condition and we need to subset (or make implicit...)
		! for most regions it is < 0.5, for the small regions it isn't just substep for now. 
! 		nsubsteps=ceiling(2*maxval(Kq_m(:,:,j)/domain%dz(2:nx+1,:nz,j)))
! 		Kq_m(:,:,j)=Kq_m(:,:,j)/nsubsteps
! 		nsubsteps will typically be 1
! 		nsubsteps=1
		where((2*Kq_m(:,:,j))>domain%dz(2:nx+1,:nz,j)) Kq_m(:,:,j)=domain%dz(2:nx+1,:nz,j)/2
! 		do t=1,nsubsteps
			! First water vapor
			call diffuse_variable(domain%qv,rhomean,rho_dz,j)
			! ditto for potential temperature
			call diffuse_variable(domain%th,rhomean,rho_dz,j)
			! and cloud water
			call diffuse_variable(domain%cloud,rhomean,rho_dz,j)
			! and cloud ice
			call diffuse_variable(domain%ice,rhomean,rho_dz,j)
			! and snow
			call diffuse_variable(domain%qsnow,rhomean,rho_dz,j)
			! don't bother with rain or graupel assuming they are falling fast *enough* not entirely fair...
! 		enddo

	end subroutine pbl_diffusion
	
	subroutine calc_shear(domain,j)
		type(domain_type), intent(in) :: domain
		integer,intent(in) :: j
		real,dimension(nx,nz+1)::centered_winds
		integer::last_wind,k
		
		centered_winds(:,:)=sqrt( ((domain%u(1:nx,:,j+1)+domain%u(2:nx+1,:,j+1))/2)**2 &
			   				     +((domain%v(2:nx+1,:,j)+domain%v(2:nx+1,:,j+1))/2)**2)
		
		shear_m(:,:,j)=abs(centered_winds(:,2:)-centered_winds(:,:nz-1))  &
		              /((domain%dz(2:nx+1,:nz-1,j+1)+domain%dz(2:nx+1,2:,j+1))*0.5)
		where(shear_m(:,:,j)<1e-5) shear_m(:,:,j)=1e-5
	end subroutine calc_shear

! 	calculate the vertical gradient in virtual potential temperature
	subroutine calc_virt_pot_temp_zgradient(domain,j)
		type(domain_type), intent(in) :: domain
		integer,intent(in)::j
		integer::k
		
! 		first calculate the virtual potential temperature
! 		vth=th*(1+0.61*qv-(qc+qi+qr+qs))
		virt_pot_temp_zgradient_m(:,:,j)=domain%th(2:nx+1,:,j+1)* &
				(1+0.61*domain%qv(2:nx+1,:,j+1) &
				 -(domain%cloud(2:nx+1,:,j+1)+domain%ice(2:nx+1,:,j+1)+domain%qrain(2:nx+1,:,j+1)+domain%qsnow(2:nx+1,:,j+1)))
		do k=1,nz
			virt_pot_temp_zgradient_m(:,k,j)=(virt_pot_temp_zgradient_m(:,k+1,j)-virt_pot_temp_zgradient_m(:,k,j)) &
											 / ((domain%dz(2:nx+1,k,j+1)+domain%dz(2:nx+1,k+1,j+1))*0.5)
		enddo
! 			
!		real,dimension(nx)::vth_row,last_vth_row
!
! 			OLDER code that will calculate virtual potential temperature gradient on full levels
! 			! for the first model level save this level for the next one and calculate the gradient
! 			! based only on the bottom two levels
! 			if (k==1) then
! 				last_vth_row=vth(:,k,j)
! 				vth(:,k,j)=(vth(:,k+1,j)-vth(:,k,j))/domain%dz(:,k,j)
! 			elseif (k==nz) then
! 				! for the top model level calculate the gradient based only on the top two levels
! 				vth(:,k,j)=(vth(:,k,j)-last_vth_row)/domain%dz(:,k,j)
! 			else
! 				! for all other levels, first save this level temporarily
! 				vth_row=vth(:,k,j)
! 				! then calculate the gradient across this level
! 				vth(:,k,j)=(vth(:,k+1,j)-last_vth_row)/ &
! 					((domain%dz(:,k-1,j)+domain%dz(:,k+1,j))*0.5+domain%dz(:,k,j))
! 				! then store the saved level in the "last" level for the next iteration
! 				last_vth_row=vth_row
! 			endif
	end subroutine calc_virt_pot_temp_zgradient

	subroutine calc_pbl_stability_function(j)
		integer,intent(in)::j
		integer::i,k
! 		HP96 eqn 13
		stability_m(:,:,j) = exp(-8.5*rig_m(:,:,j)) + 0.15 / (rig_m(:,:,j)+3)
! 		HP96 eqn 13 continued
		prandtl_m(:,:,j) = 1.5+3.08*rig_m(:,:,j)
! 		limits on Pr noted in Hong and Pan (?)
		do k=1,size(prandtl_m,2)
			do i=1,size(prandtl_m,1)
				if (prandtl_m(i,k,j)>pr_upper_limit) then
					prandtl_m(i,k,j)=pr_upper_limit
				elseif (prandtl_m(i,k,j)<pr_lower_limit) then
					prandtl_m(i,k,j)=pr_lower_limit
				endif
			enddo
		enddo
! 		alternatively... which is faster? 
! 		where(prandtl_m(:,:,j)>4) prandtl_m(:,:,j)=4
! 		where(prandtl_m(:,:,j)<0.25) prandtl_m(:,:,j)=0.25
	end subroutine calc_pbl_stability_function
	
	subroutine calc_richardson_gradient(domain,j)
! 		calculate the local gradient richardson number as in eqn. between 11 and 12 in HP96
		type(domain_type), intent(inout) :: domain
		integer,intent(in)::j
		real,dimension(nx,nz+1)::temperature
		temperature=domain%th(2:nx+1,:,j+1)*domain%pii(2:nx+1,:,j+1)
! 		might be slightly better to interpolate theta to half levels, then recalc p and pii at half levels
		temperature(:,:nz)= (temperature(:,:nz)+temperature(:,2:))*0.5
		rig_m(:,:,j) =  g/temperature(:,:nz)  & 
					   * virt_pot_temp_zgradient_m(:,:nz,j) * 1/(shear_m(:,:,j)**2)
		where(rig_m(:,:,j)<-2.9) rig_m(:,:,j)=-2.9
		
	end subroutine calc_richardson_gradient
	

! memory allocation and deallocation	
! Can/Should also add parameter definition from options%pbl (or something like that)
	subroutine init_simple_pbl(domain,options)
		type(domain_type), intent(in) :: domain
		type(options_type),intent(in) :: options
		nx=size(domain%p,1)-2
		nz=size(domain%p,2)-1
		ny=size(domain%p,3)-2
		
		allocate(virt_pot_temp_zgradient_m(nx,nz+1,ny))
		allocate(rig_m(nx,nz,ny))
		allocate(stability_m(nx,nz,ny))
		allocate(shear_m(nx,nz,ny))
		allocate(prandtl_m(nx,nz,ny))
		allocate(K_m(nx,nz,ny))
		allocate(Kq_m(nx,nz,ny))
		allocate(l_m(nx,nz,ny))
	end subroutine init_simple_pbl
	
	subroutine finalize_simple_pbl()
		if (allocated(virt_pot_temp_zgradient_m)) then
			deallocate(virt_pot_temp_zgradient_m)
		endif
		if (allocated(rig_m)) then
			deallocate(rig_m)
		endif
		if (allocated(stability_m)) then
			deallocate(stability_m)
		endif
		if (allocated(shear_m)) then
			deallocate(shear_m)
		endif
		if (allocated(prandtl_m)) then
			deallocate(prandtl_m)
		endif
		if (allocated(K_m)) then
			deallocate(K_m)
		endif
		if (allocated(Kq_m)) then
			deallocate(Kq_m)
		endif
		if (allocated(l_m)) then
			deallocate(l_m)
		endif
	end subroutine finalize_simple_pbl
end module pbl_simple