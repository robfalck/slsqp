!*******************************************************************************
!>
!  Module for the SLSQP optimization method.

    module slsqp_module

    use iso_fortran_env, only: wp => real64
    use support_module

    implicit none

    type,public :: slsqp_solver

        private

        integer :: n        = 0
        integer :: m        = 0
        integer :: meq      = 0
        integer :: max_iter = 0    !! maximum number of iterations

        real(wp) :: acc = 0.0_wp   !! accuracy tolerance

        real(wp),dimension(:),allocatable :: xl  !! lower bound on x
        real(wp),dimension(:),allocatable :: xu  !! upper bound on x

        integer :: l_w = 0 !! size of `work`
        real(wp),dimension(:),allocatable :: w !! real work array

        integer :: l_jw = 0 !! size of `jwork`
        integer,dimension(:),allocatable :: jw  !! integer work array

        procedure(func),pointer :: f => null()  !! problem function subroutine
        procedure(grad),pointer :: g => null()  !! gradient subroutine

        !formerly saved variables in slsqpb:
        real(wp) :: t       = 0.0_wp
        real(wp) :: f0      = 0.0_wp
        real(wp) :: h1      = 0.0_wp
        real(wp) :: h2      = 0.0_wp
        real(wp) :: h3      = 0.0_wp
        real(wp) :: h4      = 0.0_wp
        real(wp) :: t0      = 0.0_wp
        real(wp) :: gs      = 0.0_wp
        real(wp) :: tol     = 0.0_wp
        real(wp) :: alpha   = 0.0_wp
        integer  :: line    = 0
        integer  :: iexact  = 0
        integer  :: incons  = 0
        integer  :: ireset  = 0
        integer  :: itermx  = 0
        integer  :: n1      = 0
        integer  :: n2      = 0
        integer  :: n3      = 0

    contains

        private

        procedure,public :: initialize => initialize_slsqp
        procedure,public :: destroy    => destroy_slsqp
        procedure,public :: optimize   => slsqp_wrapper

    end type slsqp_solver

    abstract interface
        subroutine func(me,x,f,c)  !! function computation
            import :: wp,slsqp_solver
            implicit none
            class(slsqp_solver),intent(inout) :: me
            real(wp),dimension(:),intent(in)  :: x  !! optimization variable vector
            real(wp),intent(out)              :: f  !! value of the objective function
            real(wp),dimension(:),intent(out) :: c  !! the constraint vector `dimension(m)`,
                                                    !! equality constraints (if any) first.
        end subroutine func
        subroutine grad(me,x,g,a)
            import :: wp,slsqp_solver
            implicit none
            class(slsqp_solver),intent(inout)   :: me
            real(wp),dimension(:),intent(in)    :: x  !! optimization variable vector
            real(wp),dimension(:),intent(out)   :: g  !! objective function partials w.r.t x `dimension(n)`
            real(wp),dimension(:,:),intent(out) :: a  !! gradient matrix of constraints w.r.t. x `dimension(m,n)`
        end subroutine grad
    end interface

    contains
!*******************************************************************************

!*******************************************************************************
!>
!  Initialize the [[slsqp_solver]] class.  See [[slsqp]] for more details.

    subroutine initialize_slsqp(me,n,m,meq,max_iter,acc,f,g,xl,xu,status_ok)

    implicit none

    class(slsqp_solver),intent(inout) :: me
    integer,intent(in)                :: n         !! the number of varibles, n >= 1
    integer,intent(in)                :: m         !! total number of constraints, m >= 0
    integer,intent(in)                :: meq       !! number of equality constraints, meq >= 0
    integer,intent(in)                :: max_iter  !! maximum number of iterations
    procedure(func)                   :: f         !! problem function
    procedure(grad)                   :: g         !! function to compute gradients
    real(wp),dimension(n),intent(in)  :: xl        !! lower bound on `x`
    real(wp),dimension(n),intent(in)  :: xu        !! upper bound on `x`
    real(wp),intent(in)               :: acc       !! accuracy
    logical,intent(out)               :: status_ok !! will be false if there were errors

    integer :: n1,mineq

    status_ok = .false.
    call me%destroy()

    if (size(xl)/=size(xu) .or. size(xl)/=n) then
        write(*,*) 'Error: invalid upper or lower bound vector size'
    else if (meq<0 .or. meq>m) then
        write(*,*) 'Error: invalid MEQ value:', meq
    else if (m<0) then
        write(*,*) 'Error: invalid M value:', m
    else if (n<1) then
        write(*,*) 'Error: invalid N value:', n
    else if (any(xl>xu)) then
        write(*,*) 'Error: Lower bounds must be <= upper bounds.'
    else

        status_ok = .true.
        me%n = n
        me%m = m
        me%meq = meq
        me%max_iter = max_iter
        me%acc = acc
        me%f => f
        me%g => g

        allocate(me%xl(n)); me%xl = xl
        allocate(me%xu(n)); me%xu = xu

        !work arrays:
        n1 = n+1
        mineq = m - meq + 2*n1
        me%l_w = n1*(n1+1) + meq*(n1+1) + mineq*(n1+1) + &   !for lsq
                 (n1-meq+1)*(mineq+2) + 2*mineq        + &   !for lsi
                 (n1+mineq)*(n1-meq) + 2*meq + n1      + &   !for lsei
                  n1*n/2 + 2*m + 3*n +3*n1 + 1               !for slsqpb
        allocate(me%w(me%l_w))
        me%w = 0.0_wp

        me%l_jw = mineq
        allocate(me%jw(me%l_jw))
        me%jw = 0

    end if

    end subroutine initialize_slsqp
!*******************************************************************************

!*******************************************************************************
!>
!  Destructor for [[slsqp_solver]].

    subroutine destroy_slsqp(me)

    implicit none

    class(slsqp_solver),intent(out) :: me

    end subroutine destroy_slsqp
!*******************************************************************************

!*******************************************************************************
!>
!  Main routine for calling [[slsqp]].

    subroutine slsqp_wrapper(me,x,istat)

    implicit none

    class(slsqp_solver),intent(inout)   :: me
    real(wp),dimension(:),intent(inout) :: x        !! In: initialize optimization variables,
                                                    !! Out: solution.
    integer,intent(out)                 :: istat    !! status code

    real(wp)                               :: f        !! objective function
    real(wp),dimension(max(1,me%m))        :: c        !! constraint vector
    real(wp),dimension(max(1,me%m),me%n+1) :: a        !! a matrix for slsqp
    real(wp),dimension(me%n+1)             :: g        !! g matrix for slsqp
    real(wp),dimension(me%m)               :: cvec     !! constraint vector
    real(wp),dimension(me%n)               :: dfdx     !! objective function partials
    real(wp),dimension(me%m,me%n)          :: dcdx     !! constraint partials
    integer :: i,mode,la,iter
    real(wp) :: acc

    logical :: exact_linesearch = .false.   !! for now, not allowing exact linesearch (not threadsafe)

    !check setup:
    if (size(x)/=me%n) error stop 'Invalid size(x) in slsqp_wrapper'

    !initialize:
    i    = 0
    iter = me%max_iter
    la   = max(1,me%m)
    mode = 0
    a    = 0.0_wp
    g    = 0.0_wp
    c    = 0.0_wp

    if (exact_linesearch) then
        acc = -abs(me%acc)  !exact linesearch
    else
        acc = abs(me%acc)   !armijo-type linesearch
    end if

    !main solver loop:
    do

        if (mode==0 .or. mode==1) then  !function evaluation (f&c)
            call me%f(x,f,cvec)
            c(1:me%m)   = cvec

            !write(*,*) ''
            !write(*,*) 'func'       !........
            !write(*,*) 'x=',x
            !write(*,*) 'f=',f
            !write(*,*) 'c=',c

            write(*,*) i,x,f,norm2(c)
            i = i + 1

        end if

        if (mode==0 .or. mode==-1) then  !gradient evaluation (G&A)
            call me%g(x,dfdx,dcdx)
            g(1:me%n)        = dfdx
            a(1:me%m,1:me%n) = dcdx

            !write(*,*) ''
            !write(*,*) 'grad'       !........
            !write(*,*) 'x=',x
            !write(*,*) 'g=',g
            !write(*,*) 'a=',a

        end if

        !main routine:
        call slsqp(me%m,me%meq,la,me%n,x,me%xl,me%xu,&
                    f,c,g,a,acc,iter,mode,&
                    me%w,me%l_w,me%jw,me%l_jw,&
                    me%t,me%f0,me%h1,me%h2,me%h3,me%h4,&
                    me%n1,me%n2,me%n3,me%t0,me%gs,me%tol,me%line,&
                    me%alpha,me%iexact,me%incons,me%ireset,me%itermx)

        select case (mode)
        case(0) !required accuracy for solution obtained
            write(*,*) ''
            write(*,*) 'solution: ',x
            write(*,*) ''
            exit
        case(1,-1)
            !continue to next call
        case(2);
            write(*,*) 'NUMBER OF EQUALITY CONTRAINTS LARGER THAN N'
            exit
        case(3);
            write(*,*) 'MORE THAN 3*N ITERATIONS IN LSQ SUBPROBLEM'
            exit
        case(4);
            write(*,*) 'INEQUALITY CONSTRAINTS INCOMPATIBLE'
            exit
        case(5);
            write(*,*) 'SINGULAR MATRIX E IN LSQ SUBPROBLEM'
            exit
        case(6);
            write(*,*) 'SINGULAR MATRIX C IN LSQ SUBPROBLEM'
            exit
        case(7);
            write(*,*) 'RANK-DEFICIENT EQUALITY CONSTRAINT SUBPROBLEM HFTI'
            exit
        case(8);
            write(*,*) 'POSITIVE DIRECTIONAL DERIVATIVE FOR LINESEARCH'
            exit
        case(9);
            write(*,*) 'MORE THAN ITER ITERATIONS IN SQP'
            exit
        case default
            write(*,*) 'unknown SLSQP error'
            exit
        end select

    end do

    istat = mode

    end subroutine slsqp_wrapper
!*******************************************************************************

!*******************************************************************************
!>
!
!  **SLSQP**: **S**EQUENTIAL **L**EAST **SQ**UARES **P**ROGRAMMING
!  TO SOLVE GENERAL NONLINEAR OPTIMIZATION PROBLEMS
!
!  A NONLINEAR PROGRAMMING METHOD WITH QUADRATIC PROGRAMMING SUBPROBLEMS
!  THIS SUBROUTINE SOLVES THE GENERAL NONLINEAR PROGRAMMING PROBLEM:
!  **MINIMIZE**    \( F(X) \)
!  **SUBJECT TO**  \( C_J (X) = 0 \)        , \( J = 1,...,MEQ   \)
!                  \(C_J (X) \ge 0 \)       , \( J = MEQ+1,...,M \)
!                  \(XL_I <= X_I <= XU_I \) , \( I = 1,...,N     \)
!
!  THE ALGORITHM IMPLEMENTS THE METHOD OF HAN AND POWELL
!  WITH BFGS-UPDATE OF THE B-MATRIX AND L1-TEST FUNCTION
!  WITHIN THE STEPLENGTH ALGORITHM.
!
!  IMPLEMENTED BY: DIETER KRAFT, DFVLR OBERPFAFFENHOFEN
!  as described in Dieter Kraft: A Software Package for
!                                Sequential Quadratic Programming
!                                DFVLR-FB 88-28, 1988
!  which should be referenced if the user publishes results of SLSQP
!
!# History
!
!  DATE:           APRIL - OCTOBER, 1981.
!  STATUS:         DECEMBER, 31-ST, 1984.
!  STATUS:         MARCH   , 21-ST, 1987, REVISED TO FORTAN 77
!  STATUS:         MARCH   , 20-th, 1989, REVISED TO MS-FORTRAN
!  STATUS:         APRIL   , 14-th, 1989, HESSE   in-line coded
!  STATUS:         FEBRUARY, 28-th, 1991, FORTRAN/2 Version 1.04
!                                         accepts Statement Functions
!  STATUS:         MARCH   ,  1-st, 1991, tested with SALFORD
!                                         FTN77/386 COMPILER VERS 2.40
!                                         in protected mode
!  January, 2016 : refactoring into modern Fortran by Jacob Williams
!
!# License
!
!  Copyright 1991: Dieter Kraft, FHM
!  BSD License

    SUBROUTINE SLSQP(M,Meq,La,N,X,Xl,Xu,F,C,G,A,Acc,Iter,Mode,W,L_w, &
                     Jw,L_jw,&
                     t,f0,h1,h2,h3,h4,n1,n2,n3,t0,gs,tol,line,&
                     alpha,iexact,incons,ireset,itermx)

    IMPLICIT NONE

    integer,intent(in) :: M                     !! IS THE TOTAL NUMBER OF CONSTRAINTS, M >= 0
    integer,intent(in) :: MEQ                   !! IS THE NUMBER OF EQUALITY CONSTRAINTS, MEQ >= 0
    integer,intent(in) :: LA                    !! SEE A, LA >= MAX(M,1)
    integer,intent(in) :: N                     !! IS THE NUMBER OF VARIBLES, N >= 1
    real(wp),dimension(n),intent(inout) :: X    !! X() STORES THE CURRENT ITERATE OF THE N VECTOR X
                                                !! ON ENTRY X() MUST BE INITIALIZED. ON EXIT X()
                                                !! STORES THE SOLUTION VECTOR X IF MODE = 0.
    real(wp),dimension(n),intent(in) :: XL      !! XL() STORES AN N VECTOR OF LOWER BOUNDS XL TO X.
    real(wp),dimension(n),intent(in) :: XU      !! XU() STORES AN N VECTOR OF UPPER BOUNDS XU TO X.
    real(wp),intent(in) :: F                    !! IS THE VALUE OF THE OBJECTIVE FUNCTION.
    real(wp),dimension(La),intent(in) :: C      !! C() STORES THE M VECTOR C OF CONSTRAINTS,
                                                !! EQUALITY CONSTRAINTS (IF ANY) FIRST.
                                                !! DIMENSION OF C MUST BE GREATER OR EQUAL LA,
                                                !! which must be GREATER OR EQUAL MAX(1,M).
    real(wp),dimension(n+1),intent(in) :: G     !! G() STORES THE N VECTOR G OF PARTIALS OF THE
                                                !! OBJECTIVE FUNCTION; DIMENSION OF G MUST BE
                                                !! GREATER OR EQUAL N+1.
    real(wp),dimension(La,N+1),intent(in) ::  A !! THE LA BY N + 1 ARRAY A() STORES
                                                !!  THE M BY N MATRIX A OF CONSTRAINT NORMALS.
                                                !!  A() HAS FIRST DIMENSIONING PARAMETER LA,
                                                !!  WHICH MUST BE GREATER OR EQUAL MAX(1,M).
    real(wp),intent(inout) :: ACC   !! ABS(ACC) CONTROLS THE FINAL ACCURACY.
                                    !! IF ACC < ZERO AN EXACT LINESEARCH IS PERFORMED,
                                    !! OTHERWISE AN ARMIJO-TYPE LINESEARCH IS USED.
    integer,intent(inout) :: ITER   !! PRESCRIBES THE MAXIMUM NUMBER OF ITERATIONS.
                                    !! ON EXIT ITER INDICATES THE NUMBER OF ITERATIONS.
    integer,intent(inout) :: MODE   !! MODE CONTROLS CALCULATION:
                                    !! REVERSE COMMUNICATION IS USED IN THE SENSE THAT
                                    !! THE PROGRAM IS INITIALIZED BY `MODE = 0`; THEN IT IS
                                    !! TO BE CALLED REPEATEDLY BY THE USER UNTIL A RETURN
                                    !! WITH `MODE /= ABS(1)` TAKES PLACE.
                                    !! IF `MODE = -1` GRADIENTS HAVE TO BE CALCULATED,
                                    !! WHILE WITH `MODE = 1` FUNCTIONS HAVE TO BE CALCULATED.
                                    !! MODE MUST NOT BE CHANGED BETWEEN SUBSEQUENT CALLS OF SQP.
                                    !! **EVALUATION MODES**:
                                    !!    * -1 *: GRADIENT EVALUATION, (G&A)
                                    !!    *  0 *: *ON ENTRY*: INITIALIZATION, (F,G,C&A),
                                    !!            *ON EXIT*: REQUIRED ACCURACY FOR SOLUTION OBTAINED
                                    !!    *  1 *: FUNCTION EVALUATION, (F&C)
                                    !! **FAILURE MODES**:
                                    !!     * 2 *: NUMBER OF EQUALITY CONTRAINTS LARGER THAN N
                                    !!     * 3 *: MORE THAN 3*N ITERATIONS IN LSQ SUBPROBLEM
                                    !!     * 4 *: INEQUALITY CONSTRAINTS INCOMPATIBLE
                                    !!     * 5 *: SINGULAR MATRIX E IN LSQ SUBPROBLEM
                                    !!     * 6 *: SINGULAR MATRIX C IN LSQ SUBPROBLEM
                                    !!     * 7 *: RANK-DEFICIENT EQUALITY CONSTRAINT SUBPROBLEM HFTI
                                    !!     * 8 *: POSITIVE DIRECTIONAL DERIVATIVE FOR LINESEARCH
                                    !!     * 9 *: MORE THAN ITER ITERATIONS IN SQP
                                    !!  * >=10 *: WORKING SPACE W OR JW TOO SMALL,
                                    !!            W SHOULD BE ENLARGED TO L_W=MODE/1000,
                                    !!            JW SHOULD BE ENLARGED TO L_JW=MODE-1000*L_W
    integer,intent(in) :: L_W       !!   THE LENGTH of W, WHICH SHOULD BE AT LEAST:
                                    !!   (3*N1+M)*(N1+1)                        *for LSQ*
                                    !!  +(N1-MEQ+1)*(MINEQ+2) + 2*MINEQ         *for LSI*
                                    !!  +(N1+MINEQ)*(N1-MEQ) + 2*MEQ + N1       *for LSEI*
                                    !!  + N1*N/2 + 2*M + 3*N + 3*N1 + 1         *for SLSQPB*
                                    !!   with MINEQ = M - MEQ + 2*N1  &  N1 = N+1
    integer,intent(in) :: L_jw      !! THE LENGTH of Jw WHICH SHOULD BE AT LEAST
                                    !! `MINEQ = M - MEQ + 2*(N+1)`.
    real(wp),dimension(L_W),intent(inout) :: W  !! W() IS A ONE DIMENSIONAL WORKING SPACE.
                                                !! THE FIRST `M+N+N*N1/2` ELEMENTS OF W MUST NOT BE
                                                !! CHANGED BETWEEN SUBSEQUENT CALLS OF SLSQP.
                                                !! ON RETURN W(1) ... W(M) CONTAIN THE MULTIPLIERS
                                                !! ASSOCIATED WITH THE GENERAL CONSTRAINTS, WHILE
                                                !! W(M+1) ... W(M+N(N+1)/2) STORE THE CHOLESKY FACTOR
                                                !! L*D*L(T) OF THE APPROXIMATE HESSIAN OF THE
                                                !! LAGRANGIAN COLUMNWISE DENSE AS LOWER TRIANGULAR
                                                !! UNIT MATRIX L WITH D IN ITS 'DIAGONAL' and
                                                !! W(M+N(N+1)/2+N+2 ... W(M+N(N+1)/2+N+2+M+2N)
                                                !! CONTAIN THE MULTIPLIERS ASSOCIATED WITH ALL
                                                !! ALL CONSTRAINTS OF THE QUADRATIC PROGRAM FINDING
                                                !! THE SEARCH DIRECTION TO THE SOLUTION X*
    integer,dimension(L_jw),intent(inout) :: Jw !! JW() IS A ONE DIMENSIONAL INTEGER WORKING SPACE

    ! Note: F,C,G,A must all be set by the user before each call.

     real(wp),intent(inout) :: t
     real(wp),intent(inout) :: f0
     real(wp),intent(inout) :: h1
     real(wp),intent(inout) :: h2
     real(wp),intent(inout) :: h3
     real(wp),intent(inout) :: h4
     integer ,intent(inout) :: n1
     integer ,intent(inout) :: n2
     integer ,intent(inout) :: n3
     real(wp),intent(inout) :: t0
     real(wp),intent(inout) :: gs
     real(wp),intent(inout) :: tol
     integer ,intent(inout) :: line
     real(wp),intent(inout) :: alpha
     integer ,intent(inout) :: iexact
     integer ,intent(inout) :: incons
     integer ,intent(inout) :: ireset
     integer ,intent(inout) :: itermx

     INTEGER :: il , im , ir , is , iu , iv , iw , ix , mineq

!.... note: there seems to be two slightly different specifications
!     of the appropriate length of W. Are they equivalent???

     !         NOTICE:    FOR PROPER DIMENSIONING OF W IT IS RECOMMENDED TO
     !                    COPY THE FOLLOWING STATEMENTS INTO THE HEAD OF
     !                    THE CALLING PROGRAM (AND REMOVE THE COMMENT C)
     !#######################################################################
     !     INTEGER LEN_W, LEN_JW, M, N, N1, MEQ, MINEQ
     !     PARAMETER (M=... , MEQ=... , N=...  )
     !     PARAMETER (N1= N+1, MINEQ= M-MEQ+N1+N1)
     !     PARAMETER (LEN_W=
     !    $           (3*N1+M)*(N1+1)
     !    $          +(N1-MEQ+1)*(MINEQ+2) + 2*MINEQ
     !    $          +(N1+MINEQ)*(N1-MEQ) + 2*MEQ + N1
     !    $          +(N+1)*N/2 + 2*M + 3*N + 3*N1 + 1,
     !    $           LEN_JW=MINEQ)
     !     DOUBLE PRECISION W(LEN_W)
     !     INTEGER          JW(LEN_JW)
     !#######################################################################

!     dim(W) =         N1*(N1+1) + MEQ*(N1+1) + MINEQ*(N1+1)  for LSQ
!                    +(N1-MEQ+1)*(MINEQ+2) + 2*MINEQ          for LSI
!                    +(N1+MINEQ)*(N1-MEQ) + 2*MEQ + N1        for LSEI
!                    + N1*N/2 + 2*M + 3*N +3*N1 + 1           for SLSQPB
!                      with MINEQ = M - MEQ + 2*N1  &  N1 = N+1

!   CHECK LENGTH OF WORKING ARRAYS

      n1 = N + 1
      mineq = M - Meq + n1 + n1
      il = (3*n1+M)*(n1+1) + (n1-Meq+1)*(mineq+2) + 2*mineq + (n1+mineq)&
           *(n1-Meq) + 2*Meq + n1*N/2 + 2*M + 3*N + 4*n1 + 1
      im = MAX(mineq,n1-Meq)
      IF ( L_w<il .OR. L_jw<im ) THEN
         Mode = 1000*MAX(10,il)
         Mode = Mode + MAX(10,im)
         RETURN
      ENDIF

!   PREPARE DATA FOR CALLING SQPBDY  -  INITIAL ADDRESSES IN W

      im = 1
      il = im + MAX(1,M)
      il = im + La
      ix = il + n1*N/2 + 1
      ir = ix + N
      is = ir + N + N + MAX(1,M)
      is = ir + N + N + La
      iu = is + n1
      iv = iu + n1
      iw = iv + n1

      CALL SLSQPB(M,Meq,La,N,X,Xl,Xu,F,C,G,A,Acc,Iter,Mode,W(ir),W(il), &
                  W(ix),W(im),W(is),W(iu),W(iv),W(iw),Jw,&
                  t,f0,h1,h2,h3,h4,n1,n2,n3,t0,gs,tol,line,&
                  alpha,iexact,incons,ireset,itermx)

      END SUBROUTINE SLSQP
!*******************************************************************************

!*******************************************************************************
!>
!  NONLINEAR PROGRAMMING BY SOLVING SEQUENTIALLY QUADRATIC programs
!
!  L1 - LINE SEARCH,  POSITIVE DEFINITE  BFGS UPDATE

    SUBROUTINE SLSQPB(M,Meq,La,N,X,Xl,Xu,F,C,G,A,Acc,Iter,Mode,R,L,X0,&
                      Mu,S,U,V,W,Iw,&
                      t,f0,h1,h2,h3,h4,n1,n2,n3,t0,gs,tol,line,&
                      alpha,iexact,incons,ireset,itermx)
    IMPLICIT NONE

    real(wp) ,intent(inout) :: t
    real(wp) ,intent(inout) :: f0
    real(wp) ,intent(inout) :: h1
    real(wp) ,intent(inout) :: h2
    real(wp) ,intent(inout) :: h3
    real(wp) ,intent(inout) :: h4
    integer  ,intent(inout) :: n1
    integer  ,intent(inout) :: n2
    integer  ,intent(inout) :: n3
    real(wp) ,intent(inout) :: t0
    real(wp) ,intent(inout) :: gs
    real(wp) ,intent(inout) :: tol
    integer  ,intent(inout) :: line
    real(wp) ,intent(inout) :: alpha
    integer  ,intent(inout) :: iexact
    integer  ,intent(inout) :: incons
    integer  ,intent(inout) :: ireset
    integer  ,intent(inout) :: itermx

    INTEGER :: Iw(*), i, Iter, k, j, La, M, Meq, Mode, N

    real(wp) :: A(La,N+1) , C(La) , G(N+1) , L((N+1)*(N+2)/2) , &
                  Mu(La) , R(M+N+N+2) , S(N+1) , U(N+1) , V(N+1) , &
                  W(*) , X(N) , Xl(N) , Xu(N) , X0(N) , &
                  Acc , F

!     dim(W) =         N1*(N1+1) + MEQ*(N1+1) + MINEQ*(N1+1)  for LSQ
!                     +(N1-MEQ+1)*(MINEQ+2) + 2*MINEQ
!                     +(N1+MINEQ)*(N1-MEQ) + 2*MEQ + N1       for LSEI
!                      with MINEQ = M - MEQ + 2*N1  &  N1 = N+1

!      SAVE alpha , f0 , gs , h1 , h2 , h3 , h4 , t , t0 , tol , iexact ,&
!         incons , ireset , itermx , line , n1 , n2 , n3

      real(wp),parameter :: zero   = 0.0_wp
      real(wp),parameter :: one    = 1.0_wp
      real(wp),parameter :: two    = 2.0_wp
      real(wp),parameter :: ten    = 10.0_wp
      real(wp),parameter :: hun    = 100.0_wp
      real(wp),parameter :: alfmin = 0.1_wp

      IF ( Mode<0 ) THEN

!   CALL JACOBIAN AT CURRENT X

!   UPDATE CHOLESKY-FACTORS OF HESSIAN MATRIX BY MODIFIED BFGS FORMULA

         DO i = 1 , N
            U(i) = G(i) - DDOT(M,A(1,i),1,R,1) - V(i)
         ENDDO

!   L'*S

         k = 0
         DO i = 1 , N
            h1 = zero
            k = k + 1
            DO j = i + 1 , N
               k = k + 1
               h1 = h1 + L(k)*S(j)
            ENDDO
            V(i) = S(i) + h1
         ENDDO

!   D*L'*S

         k = 1
         DO i = 1 , N
            V(i) = L(k)*V(i)
            k = k + n1 - i
         ENDDO

!   L*D*L'*S

         DO i = N , 1 , -1
            h1 = zero
            k = i
            DO j = 1 , i - 1
               h1 = h1 + L(k)*V(j)
               k = k + N - j
            ENDDO
            V(i) = V(i) + h1
         ENDDO

         h1 = DDOT(N,S,1,U,1)
         h2 = DDOT(N,S,1,V,1)
         h3 = 0.2_wp*h2
         IF ( h1<h3 ) THEN
            h4 = (h2-h3)/(h2-h1)
            h1 = h3
            CALL DSCAL(N,h4,U,1)
            CALL DAXPY(N,one-h4,V,1,U,1)
         ENDIF
         CALL LDL(N,L,U,+one/h1,V)
         CALL LDL(N,L,V,-one/h2,U)

!   END OF MAIN ITERATION

         GOTO 200
      ELSEIF ( Mode==0 ) THEN

         itermx = Iter
         IF ( Acc>=zero ) THEN
            iexact = 0
         ELSE
            iexact = 1
         ENDIF
         Acc = ABS(Acc)
         tol = ten*Acc
         Iter = 0
         ireset = 0
         n1 = N + 1
         n2 = n1*N/2
         n3 = n2 + 1
         S(1) = zero
         Mu(1) = zero
         CALL DCOPY(N,S(1),0,S,1)
         CALL DCOPY(M,Mu(1),0,Mu,1)
      ELSE

!   CALL FUNCTIONS AT CURRENT X

         t = F
         DO j = 1 , M
            IF ( j<=Meq ) THEN
               h1 = C(j)
            ELSE
               h1 = zero
            ENDIF
            t = t + Mu(j)*MAX(-C(j),h1)
         ENDDO
         h1 = t - t0
         IF ( iexact+1==1 ) THEN
            IF ( h1<=h3/ten .OR. line>10 ) GOTO 500
            alpha = MAX(h3/(two*(h3-h1)),alfmin)
            GOTO 300
         ELSEIF ( iexact+1==2 ) THEN
            GOTO 400
         ELSE
            GOTO 500
         ENDIF
      ENDIF

!   RESET BFGS MATRIX

 100  ireset = ireset + 1
      IF ( ireset>5 ) THEN

!   CHECK relaxed CONVERGENCE in case of positive directional derivative

         IF ( (ABS(F-f0)<tol .OR. DNRM2(N,S,1)<tol) .AND. h3<tol ) THEN
            Mode = 0
         ELSE
            Mode = 8
         ENDIF
         return
      ELSE
         L(1) = zero
         CALL DCOPY(n2,L(1),0,L,1)
         j = 1
         DO i = 1 , N
            L(j) = one
            j = j + n1 - i
         ENDDO
      ENDIF

!   MAIN ITERATION : SEARCH DIRECTION, STEPLENGTH, LDL'-UPDATE

 200  Iter = Iter + 1
      Mode = 9
      IF ( Iter>itermx ) return

!   SEARCH DIRECTION AS SOLUTION OF QP - SUBPROBLEM

      CALL DCOPY(N,Xl,1,U,1)
      CALL DCOPY(N,Xu,1,V,1)
      CALL DAXPY(N,-one,X,1,U,1)
      CALL DAXPY(N,-one,X,1,V,1)
      h4 = one
      CALL LSQ(M,Meq,N,n3,La,L,G,A,C,U,V,S,R,W,Iw,Mode)

!   AUGMENTED PROBLEM FOR INCONSISTENT LINEARIZATION

      IF ( Mode==6 ) THEN
         IF ( N==Meq ) Mode = 4
      ENDIF
      IF ( Mode==4 ) THEN
         DO j = 1 , M
            IF ( j<=Meq ) THEN
               A(j,n1) = -C(j)
            ELSE
               A(j,n1) = MAX(-C(j),zero)
            ENDIF
         ENDDO
         S(1) = zero
         CALL DCOPY(N,S(1),0,S,1)
         h3 = zero
         G(n1) = zero
         L(n3) = hun
         S(n1) = one
         U(n1) = zero
         V(n1) = one
         incons = 0
 250     CALL LSQ(M,Meq,n1,n3,La,L,G,A,C,U,V,S,R,W,Iw,Mode)
         h4 = one - S(n1)
         IF ( Mode==4 ) THEN
            L(n3) = ten*L(n3)
            incons = incons + 1
            IF ( incons<=5 ) GOTO 250
            return
         ELSEIF ( Mode/=1 ) THEN
            return
         ENDIF
      ELSEIF ( Mode/=1 ) THEN
         return
      ENDIF

!   UPDATE MULTIPLIERS FOR L1-TEST

      DO i = 1 , N
         V(i) = G(i) - DDOT(M,A(1,i),1,R,1)
      ENDDO
      f0 = F
      CALL DCOPY(N,X,1,X0,1)
      gs = DDOT(N,G,1,S,1)
      h1 = ABS(gs)
      h2 = zero
      DO j = 1 , M
         IF ( j<=Meq ) THEN
            h3 = C(j)
         ELSE
            h3 = zero
         ENDIF
         h2 = h2 + MAX(-C(j),h3)
         h3 = ABS(R(j))
         Mu(j) = MAX(h3,(Mu(j)+h3)/two)
         h1 = h1 + h3*ABS(C(j))
      ENDDO

!   CHECK CONVERGENCE

      Mode = 0
      IF ( h1<Acc .AND. h2<Acc ) return
      h1 = zero
      DO j = 1 , M
         IF ( j<=Meq ) THEN
            h3 = C(j)
         ELSE
            h3 = zero
         ENDIF
         h1 = h1 + Mu(j)*MAX(-C(j),h3)
      ENDDO
      t0 = F + h1
      h3 = gs - h1*h4
      Mode = 8
      IF ( h3>=zero ) GOTO 100

!   LINE SEARCH WITH AN L1-TESTFUNCTION

      line = 0
      alpha = one
      IF ( iexact==1 ) GOTO 400

!   INEXACT LINESEARCH

 300  line = line + 1
      h3 = alpha*h3
      CALL DSCAL(N,alpha,S,1)
      CALL DCOPY(N,X0,1,X,1)
      CALL DAXPY(N,one,S,1,X,1)

      call enforce_bounds(x,xl,xu)  ! ensure that x doesn't violate bounds

      Mode = 1
      return

!   EXACT LINESEARCH

 400  IF ( line/=3 ) THEN
         alpha = LINMIN(line,alfmin,one,t,tol)
         CALL DCOPY(N,X0,1,X,1)
         CALL DAXPY(N,alpha,S,1,X,1)
         Mode = 1
         return
      ENDIF
      CALL DSCAL(N,alpha,S,1)

!   CHECK CONVERGENCE

 500  h3 = zero
      DO j = 1 , M
         IF ( j<=Meq ) THEN
            h1 = C(j)
         ELSE
            h1 = zero
         ENDIF
         h3 = h3 + MAX(-C(j),h1)
      ENDDO
      IF ( (ABS(F-f0)<Acc .OR. DNRM2(N,S,1)<Acc) .AND. h3<Acc ) THEN
         Mode = 0
      ELSE
         Mode = -1
      ENDIF

      END SUBROUTINE SLSQPB
!*******************************************************************************

!*******************************************************************************
!>
!   MINIMIZE with respect to X
!
!             ||E*X - F||
!                                      1/2  T
!   WITH UPPER TRIANGULAR MATRIX E = +D   *L ,
!
!                                      -1/2  -1
!                     AND VECTOR F = -D    *L  *G,
!
!  WHERE THE UNIT LOWER TRIDIANGULAR MATRIX L IS STORED COLUMNWISE
!  DENSE IN THE N*(N+1)/2 ARRAY L WITH VECTOR D STORED IN ITS
! 'DIAGONAL' THUS SUBSTITUTING THE ONE-ELEMENTS OF L
!
!   SUBJECT TO
!
!             A(J)*X - B(J) = 0 ,         J=1,...,MEQ,
!             A(J)*X - B(J) >=0,          J=MEQ+1,...,M,
!             XL(I) <= X(I) <= XU(I),     I=1,...,N,
!     ON ENTRY, THE USER HAS TO PROVIDE THE ARRAYS L, G, A, B, XL, XU.
!     WITH DIMENSIONS: L(N*(N+1)/2), G(N), A(LA,N), B(M), XL(N), XU(N)
!     THE WORKING ARRAY W MUST HAVE AT LEAST THE FOLLOWING DIMENSION:
!     DIM(W) =        (3*N+M)*(N+1)                        for LSQ
!                    +(N-MEQ+1)*(MINEQ+2) + 2*MINEQ        for LSI
!                    +(N+MINEQ)*(N-MEQ) + 2*MEQ + N        for LSEI
!                      with MINEQ = M - MEQ + 2*N
!     ON RETURN, NO ARRAY WILL BE CHANGED BY THE SUBROUTINE.
!     X     STORES THE N-DIMENSIONAL SOLUTION VECTOR
!     Y     STORES THE VECTOR OF LAGRANGE MULTIPLIERS OF DIMENSION
!           M+N+N (CONSTRAINTS+LOWER+UPPER BOUNDS)
!     MODE  IS A SUCCESS-FAILURE FLAG WITH THE FOLLOWING MEANINGS:
!          MODE=1: SUCCESSFUL COMPUTATION
!               2: ERROR RETURN BECAUSE OF WRONG DIMENSIONS (N<1)
!               3: ITERATION COUNT EXCEEDED BY NNLS
!               4: INEQUALITY CONSTRAINTS INCOMPATIBLE
!               5: MATRIX E IS NOT OF FULL RANK
!               6: MATRIX C IS NOT OF FULL RANK
!               7: RANK DEFECT IN HFTI
!
!     coded            Dieter Kraft, april 1987
!     revised                        march 1989

    SUBROUTINE LSQ(M,Meq,N,Nl,La,L,G,A,B,Xl,Xu,X,Y,W,Jw,Mode)
    IMPLICIT NONE

      real(wp) :: L , G , A , B , W , Xl , Xu , X , Y , diag , xnorm

      INTEGER :: Jw(*) , i , ic , id , ie , if , ig , ih , il , im , ip , &
                 iu , iw , i1 , i2 , i3 , i4 , La , M , Meq , mineq , &
                 Mode , m1 , N , Nl , n1 , n2 , n3

      DIMENSION A(La,N) , B(La) , G(N) , L(Nl) , W(*) , X(N) , Xl(N) , &
                Xu(N) , Y(M+N+N)

      real(wp),parameter :: zero = 0.0_wp
      real(wp),parameter :: one  = 1.0_wp

      n1 = N + 1
      mineq = M - Meq
      m1 = mineq + N + N

      !  determine whether to solve problem
      !  with inconsistent linerarization (n2=1)
      !  or not (n2=0)

      n2 = n1*N/2 + 1
      IF ( n2==Nl ) THEN
         n2 = 0
      ELSE
         n2 = 1
      ENDIF
      n3 = N - n2

      !  RECOVER MATRIX E AND VECTOR F FROM L AND G

      i2 = 1
      i3 = 1
      i4 = 1
      ie = 1
      if = N*N + 1
      DO i = 1 , n3
         i1 = n1 - i
         diag = SQRT(L(i2))
         W(i3) = zero
         CALL DCOPY(i1,W(i3),0,W(i3),1)
         CALL DCOPY(i1-n2,L(i2),1,W(i3),N)
         CALL DSCAL(i1-n2,diag,W(i3),N)
         W(i3) = diag
         W(if-1+i) = (G(i)-DDOT(i-1,W(i4),1,W(if),1))/diag
         i2 = i2 + i1 - n2
         i3 = i3 + n1
         i4 = i4 + N
      ENDDO
      IF ( n2==1 ) THEN
         W(i3) = L(Nl)
         W(i4) = zero
         CALL DCOPY(n3,W(i4),0,W(i4),1)
         W(if-1+N) = zero
      ENDIF
      CALL DSCAL(N,-one,W(if),1)

      ic = if + N
      id = ic + Meq*N

      IF ( Meq>0 ) THEN

         !  RECOVER MATRIX C FROM UPPER PART OF A

         DO i = 1 , Meq
            CALL DCOPY(N,A(i,1),La,W(ic-1+i),Meq)
         ENDDO

         !  RECOVER VECTOR D FROM UPPER PART OF B

         CALL DCOPY(Meq,B(1),1,W(id),1)
         CALL DSCAL(Meq,-one,W(id),1)

      ENDIF

      ig = id + Meq

      IF ( mineq>0 ) THEN
         !  RECOVER MATRIX G FROM LOWER PART OF A
         DO i = 1 , mineq
            CALL DCOPY(N,A(Meq+i,1),La,W(ig-1+i),m1)
         ENDDO
      ENDIF

      !  AUGMENT MATRIX G BY +I AND -I

      ip = ig + mineq
      DO i = 1 , N
         W(ip-1+i) = zero
         CALL DCOPY(N,W(ip-1+i),0,W(ip-1+i),m1)
      ENDDO
      W(ip) = one
      CALL DCOPY(N,W(ip),0,W(ip),m1+1)

      im = ip + N
      DO i = 1 , N
         W(im-1+i) = zero
         CALL DCOPY(N,W(im-1+i),0,W(im-1+i),m1)
      ENDDO
      W(im) = -one
      CALL DCOPY(N,W(im),0,W(im),m1+1)

      ih = ig + m1*N

      IF ( mineq>0 ) THEN
         ! RECOVER H FROM LOWER PART OF B
         CALL DCOPY(mineq,B(Meq+1),1,W(ih),1)
         CALL DSCAL(mineq,-one,W(ih),1)
      ENDIF

      !  AUGMENT VECTOR H BY XL AND XU

      il = ih + mineq
      CALL DCOPY(N,Xl,1,W(il),1)
      iu = il + N
      CALL DCOPY(N,Xu,1,W(iu),1)
      CALL DSCAL(N,-one,W(iu),1)

      iw = iu + N

      CALL LSEI(W(ic),W(id),W(ie),W(if),W(ig),W(ih),MAX(1,Meq),Meq,N,N, &
                m1,m1,N,X,xnorm,W(iw),Jw,Mode)

      IF ( Mode==1 ) THEN
         ! restore Lagrange multipliers
         CALL DCOPY(M,W(iw),1,Y(1),1)
         CALL DCOPY(n3,W(iw+M),1,Y(M+1),1)
         CALL DCOPY(n3,W(iw+M+N),1,Y(M+n3+1),1)
         call enforce_bounds(x,xl,xu)  ! to ensure that bounds are not violated
      ENDIF

      END SUBROUTINE LSQ
!*******************************************************************************

!*******************************************************************************
!>
!
!  FOR MODE=1, THE SUBROUTINE RETURNS THE SOLUTION X OF
!  EQUALITY & INEQUALITY CONSTRAINED LEAST SQUARES PROBLEM LSEI :
!
!                MIN ||E*X - F||
!                 X
!
!                S.T.  C*X  = D,
!                      G*X >= H.
!
!     USING QR DECOMPOSITION & ORTHOGONAL BASIS OF NULLSPACE OF C
!     CHAPTER 23.6 OF LAWSON & HANSON: SOLVING LEAST SQUARES PROBLEMS.
!
!     THE FOLLOWING DIMENSIONS OF THE ARRAYS DEFINING THE PROBLEM
!     ARE NECESSARY
!     DIM(E) :   FORMAL (LE,N),    ACTUAL (ME,N)
!     DIM(F) :   FORMAL (LE  ),    ACTUAL (ME  )
!     DIM(C) :   FORMAL (LC,N),    ACTUAL (MC,N)
!     DIM(D) :   FORMAL (LC  ),    ACTUAL (MC  )
!     DIM(G) :   FORMAL (LG,N),    ACTUAL (MG,N)
!     DIM(H) :   FORMAL (LG  ),    ACTUAL (MG  )
!     DIM(X) :   FORMAL (N   ),    ACTUAL (N   )
!     DIM(W) :   2*MC+ME+(ME+MG)*(N-MC)  for LSEI
!              +(N-MC+1)*(MG+2)+2*MG     for LSI
!     DIM(JW):   MAX(MG,L)
!     ON ENTRY, THE USER HAS TO PROVIDE THE ARRAYS C, D, E, F, G, AND H.
!     ON RETURN, ALL ARRAYS WILL BE CHANGED BY THE SUBROUTINE.
!     X     STORES THE SOLUTION VECTOR
!     XNORM STORES THE RESIDUUM OF THE SOLUTION IN EUCLIDIAN NORM
!     W     STORES THE VECTOR OF LAGRANGE MULTIPLIERS IN ITS FIRST
!           MC+MG ELEMENTS
!     MODE  IS A SUCCESS-FAILURE FLAG WITH THE FOLLOWING MEANINGS:
!          MODE=1: SUCCESSFUL COMPUTATION
!               2: ERROR RETURN BECAUSE OF WRONG DIMENSIONS (N<1)
!               3: ITERATION COUNT EXCEEDED BY NNLS
!               4: INEQUALITY CONSTRAINTS INCOMPATIBLE
!               5: MATRIX E IS NOT OF FULL RANK
!               6: MATRIX C IS NOT OF FULL RANK
!               7: RANK DEFECT IN HFTI
!
!     18.5.1981, DIETER KRAFT, DFVLR OBERPFAFFENHOFEN
!     20.3.1987, DIETER KRAFT, DFVLR OBERPFAFFENHOFEN

    SUBROUTINE LSEI(C,D,E,F,G,H,Lc,Mc,Le,Me,Lg,Mg,N,X,Xnrm,W,Jw,Mode)
    IMPLICIT NONE

      INTEGER :: Jw(*) , i , ie , if , ig , iw , j , k , krank , l , Lc , &
                 Le , Lg , Mc , mc1 , Me , Mg , Mode , N
      real(wp) :: C(Lc,N) , E(Le,N) , G(Lg,N) , D(Lc) , F(Le) , &
                  H(Lg) , X(N) , W(*) , t , Xnrm , dum(1)

      real(wp),parameter :: epmach = epsilon(1.0_wp)
      real(wp),parameter :: zero   = 0.0_wp

      Mode = 2
      IF ( Mc<=N ) THEN
         l = N - Mc
         mc1 = Mc + 1
         iw = (l+1)*(Mg+2) + 2*Mg + Mc
         ie = iw + Mc + 1
         if = ie + Me*l
         ig = if + Me

!  TRIANGULARIZE C AND APPLY FACTORS TO E AND G

         DO i = 1 , Mc
            j = MIN(i+1,Lc)
            CALL H12(1,i,i+1,N,C(i,1),Lc,W(iw+i),C(j,1),Lc,1,Mc-i)
            CALL H12(2,i,i+1,N,C(i,1),Lc,W(iw+i),E,Le,1,Me)
            CALL H12(2,i,i+1,N,C(i,1),Lc,W(iw+i),G,Lg,1,Mg)
         ENDDO

!  SOLVE C*X=D AND MODIFY F

         Mode = 6
         DO i = 1 , Mc
            IF ( ABS(C(i,i))<epmach ) return
            X(i) = (D(i)-DDOT(i-1,C(i,1),Lc,X,1))/C(i,i)
         ENDDO
         Mode = 1
         W(mc1) = zero
         !CALL DCOPY(Mg-Mc,W(mc1),0,W(mc1),1)  ! original code
         CALL DCOPY(Mg,W(mc1),0,W(mc1),1)      ! bug fix for when meq = n

         IF ( Mc/=N ) THEN

            DO i = 1 , Me
               W(if-1+i) = F(i) - DDOT(Mc,E(i,1),Le,X,1)
            ENDDO

!  STORE TRANSFORMED E & G

            DO i = 1 , Me
               CALL DCOPY(l,E(i,mc1),Le,W(ie-1+i),Me)
            ENDDO
            DO i = 1 , Mg
               CALL DCOPY(l,G(i,mc1),Lg,W(ig-1+i),Mg)
            ENDDO

            IF ( Mg>0 ) THEN
!  MODIFY H AND SOLVE INEQUALITY CONSTRAINED LS PROBLEM

               DO i = 1 , Mg
                  H(i) = H(i) - DDOT(Mc,G(i,1),Lg,X,1)
               ENDDO
               CALL LSI(W(ie),W(if),W(ig),H,Me,Me,Mg,Mg,l,X(mc1),Xnrm,  &
                        W(mc1),Jw,Mode)
               IF ( Mc==0 ) return
               t = DNRM2(Mc,X,1)
               Xnrm = SQRT(Xnrm*Xnrm+t*t)
               IF ( Mode/=1 ) return
            ELSE

!  SOLVE LS WITHOUT INEQUALITY CONSTRAINTS

               Mode = 7
               k = MAX(Le,N)
               t = SQRT(epmach)
               CALL HFTI(W(ie),Me,Me,l,W(if),k,1,t,krank,dum,W,W(l+1),Jw)
               Xnrm = dum(1)
               CALL DCOPY(l,W(if),1,X(mc1),1)
               IF ( krank/=l ) return
               Mode = 1
            ENDIF
         ENDIF

!  SOLUTION OF ORIGINAL PROBLEM AND LAGRANGE MULTIPLIERS

         DO i = 1 , Me
            F(i) = DDOT(N,E(i,1),Le,X,1) - F(i)
         ENDDO
         DO i = 1 , Mc
            D(i) = DDOT(Me,E(1,i),1,F,1) &
                   - DDOT(Mg,G(1,i),1,W(mc1),1)
         ENDDO

         DO i = Mc , 1 , -1
            CALL H12(2,i,i+1,N,C(i,1),Lc,W(iw+i),X,1,1,1)
         ENDDO

         DO i = Mc , 1 , -1
            j = MIN(i+1,Lc)
            W(i) = (D(i)-DDOT(Mc-i,C(j,i),1,W(j),1))/C(i,i)
         ENDDO
      ENDIF

      END SUBROUTINE LSEI
!*******************************************************************************

!*******************************************************************************
!>
!
!  FOR MODE=1, THE SUBROUTINE RETURNS THE SOLUTION X OF
!  INEQUALITY CONSTRAINED LINEAR LEAST SQUARES PROBLEM:
!
!                    MIN ||E*X-F||
!                     X
!
!                    S.T.  G*X >= H
!
!     THE ALGORITHM IS BASED ON QR DECOMPOSITION AS DESCRIBED IN
!     CHAPTER 23.5 OF LAWSON & HANSON: SOLVING LEAST SQUARES PROBLEMS
!
!     THE FOLLOWING DIMENSIONS OF THE ARRAYS DEFINING THE PROBLEM
!     ARE NECESSARY
!     DIM(E) :   FORMAL (LE,N),    ACTUAL (ME,N)
!     DIM(F) :   FORMAL (LE  ),    ACTUAL (ME  )
!     DIM(G) :   FORMAL (LG,N),    ACTUAL (MG,N)
!     DIM(H) :   FORMAL (LG  ),    ACTUAL (MG  )
!     DIM(X) :   N
!     DIM(W) :   (N+1)*(MG+2) + 2*MG
!     DIM(JW):   LG
!     ON ENTRY, THE USER HAS TO PROVIDE THE ARRAYS E, F, G, AND H.
!     ON RETURN, ALL ARRAYS WILL BE CHANGED BY THE SUBROUTINE.
!     X     STORES THE SOLUTION VECTOR
!     XNORM STORES THE RESIDUUM OF THE SOLUTION IN EUCLIDIAN NORM
!     W     STORES THE VECTOR OF LAGRANGE MULTIPLIERS IN ITS FIRST
!           MG ELEMENTS
!     MODE  IS A SUCCESS-FAILURE FLAG WITH THE FOLLOWING MEANINGS:
!          MODE=1: SUCCESSFUL COMPUTATION
!               2: ERROR RETURN BECAUSE OF WRONG DIMENSIONS (N<1)
!               3: ITERATION COUNT EXCEEDED BY NNLS
!               4: INEQUALITY CONSTRAINTS INCOMPATIBLE
!               5: MATRIX E IS NOT OF FULL RANK
!
!     03.01.1980, DIETER KRAFT: CODED
!     20.03.1987, DIETER KRAFT: REVISED TO FORTRAN 77

    SUBROUTINE LSI(E,F,G,H,Le,Me,Lg,Mg,N,X,Xnorm,W,Jw,Mode)
    IMPLICIT NONE

      INTEGER :: i , j , Le , Lg , Me , Mg , Mode , N , Jw(Lg)
      real(wp) :: E(Le,N) , F(Le) , G(Lg,N) , H(Lg) , X(N) , W(*) , &
                  Xnorm , t

      real(wp),parameter :: epmach = epsilon(1.0_wp)
      real(wp),parameter :: one    = 1.0_wp

!  QR-FACTORS OF E AND APPLICATION TO F

      DO i = 1 , N
         j = MIN(i+1,N)
         CALL H12(1,i,i+1,Me,E(1,i),1,t,E(1,j),1,Le,N-i)
         CALL H12(2,i,i+1,Me,E(1,i),1,t,F,1,1,1)
      ENDDO

!  TRANSFORM G AND H TO GET LEAST DISTANCE PROBLEM

      Mode = 5
      DO i = 1 , Mg
         DO j = 1 , N
            IF ( ABS(E(j,j))<epmach ) return
            G(i,j) = (G(i,j)-DDOT(j-1,G(i,1),Lg,E(1,j),1))/E(j,j)
         ENDDO
         H(i) = H(i) - DDOT(N,G(i,1),Lg,F,1)
      ENDDO

!  SOLVE LEAST DISTANCE PROBLEM

      CALL LDP(G,Lg,Mg,N,H,X,Xnorm,W,Jw,Mode)
      IF ( Mode==1 ) THEN

!  SOLUTION OF ORIGINAL PROBLEM

         CALL DAXPY(N,one,F,1,X,1)
         DO i = N , 1 , -1
            j = MIN(i+1,N)
            X(i) = (X(i)-DDOT(N-i,E(i,j),Le,X(j),1))/E(i,i)
         ENDDO
         j = MIN(N+1,Me)
         t = DNRM2(Me-N,F(j),1)
         Xnorm = SQRT(Xnorm*Xnorm+t*t)
      ENDIF

      END SUBROUTINE LSI
!*******************************************************************************

!*******************************************************************************
!>
!
!                     T
!     MINIMIZE   1/2 X X    SUBJECT TO   G * X >= H.
!
!       C.L. LAWSON, R.J. HANSON: 'SOLVING LEAST SQUARES PROBLEMS'
!       PRENTICE HALL, ENGLEWOOD CLIFFS, NEW JERSEY, 1974.
!
!     PARAMETER DESCRIPTION:
!
!     G(),MG,M,N   ON ENTRY G() STORES THE M BY N MATRIX OF
!                  LINEAR INEQUALITY CONSTRAINTS. G() HAS FIRST
!                  DIMENSIONING PARAMETER MG
!     H()          ON ENTRY H() STORES THE M VECTOR H REPRESENTING
!                  THE RIGHT SIDE OF THE INEQUALITY SYSTEM
!
!     REMARK: G(),H() WILL NOT BE CHANGED DURING CALCULATIONS BY LDP
!
!     X()          ON ENTRY X() NEED NOT BE INITIALIZED.
!                  ON EXIT X() STORES THE SOLUTION VECTOR X IF MODE=1.
!     XNORM        ON EXIT XNORM STORES THE EUCLIDIAN NORM OF THE
!                  SOLUTION VECTOR IF COMPUTATION IS SUCCESSFUL
!     W()          W IS A ONE DIMENSIONAL WORKING SPACE, THE LENGTH
!                  OF WHICH SHOULD BE AT LEAST (M+2)*(N+1) + 2*M
!                  ON EXIT W() STORES THE LAGRANGE MULTIPLIERS
!                  ASSOCIATED WITH THE CONSTRAINTS
!                  AT THE SOLUTION OF PROBLEM LDP
!     INDEX()      INDEX() IS A ONE DIMENSIONAL INTEGER WORKING SPACE
!                  OF LENGTH AT LEAST M
!     MODE         MODE IS A SUCCESS-FAILURE FLAG WITH THE FOLLOWING
!                  MEANINGS:
!          MODE=1: SUCCESSFUL COMPUTATION
!               2: ERROR RETURN BECAUSE OF WRONG DIMENSIONS (N<=0)
!               3: ITERATION COUNT EXCEEDED BY NNLS
!               4: INEQUALITY CONSTRAINTS INCOMPATIBLE

    SUBROUTINE LDP(G,Mg,M,N,H,X,Xnorm,W,Index,Mode)
    IMPLICIT NONE

      real(wp) :: G , H , X , Xnorm , W , u , v , fac , rnorm
      INTEGER :: Index , i , if , iw , iwdual , iy , iz , j , M , Mg , &
                 Mode , N , n1

      DIMENSION G(Mg,N) , H(M) , X(N) , W(*) , Index(M)

      real(wp),parameter :: zero = 0.0_wp
      real(wp),parameter :: one  = 1.0_wp

      Mode = 2
      IF ( N>0 ) THEN

!  STATE DUAL PROBLEM

         Mode = 1
         X(1) = zero
         CALL DCOPY(N,X(1),0,X,1)
         Xnorm = zero
         IF ( M/=0 ) THEN
            iw = 0
            DO j = 1 , M
               DO i = 1 , N
                  iw = iw + 1
                  W(iw) = G(j,i)
               ENDDO
               iw = iw + 1
               W(iw) = H(j)
            ENDDO
            if = iw + 1
            DO i = 1 , N
               iw = iw + 1
               W(iw) = zero
            ENDDO
            W(iw+1) = one
            n1 = N + 1
            iz = iw + 2
            iy = iz + n1
            iwdual = iy + M

!  SOLVE DUAL PROBLEM

            CALL NNLS(W,n1,n1,M,W(if),W(iy),rnorm,W(iwdual),W(iz),Index,Mode)

            IF ( Mode==1 ) THEN
               Mode = 4
               IF ( rnorm>zero ) THEN

!  COMPUTE SOLUTION OF PRIMAL PROBLEM

                  fac = one - DDOT(M,H,1,W(iy),1)
                  IF ( DIFF(one+fac,one)>zero ) THEN
                     Mode = 1
                     fac = one/fac
                     DO j = 1 , N
                        X(j) = fac*DDOT(M,G(1,j),1,W(iy),1)
                     ENDDO
                     Xnorm = DNRM2(N,X,1)

!  COMPUTE LAGRANGE MULTIPLIERS FOR PRIMAL PROBLEM

                     W(1) = zero
                     CALL DCOPY(M,W(1),0,W,1)
                     CALL DAXPY(M,fac,W(iy),1,W,1)
                  ENDIF
               ENDIF
            ENDIF
         ENDIF
      ENDIF

      END SUBROUTINE LDP
!*******************************************************************************

!*******************************************************************************
    pure elemental function DIFF(u,v) result(d)
        !! replaced statement function in original code
        implicit none
        real(wp),intent(in) :: u
        real(wp),intent(in) :: v
        real(wp) :: d
        d = u - v
    end function DIFF
!*******************************************************************************

!*******************************************************************************
!>
!  C.L.LAWSON AND R.J.HANSON, JET PROPULSION LABORATORY:
!  'SOLVING LEAST SQUARES PROBLEMS'. PRENTICE-HALL.1974
!
!      **********   NONNEGATIVE LEAST SQUARES   **********
!
!     GIVEN AN M BY N MATRIX, A, AND AN M-VECTOR, B, COMPUTE AN
!     N-VECTOR, X, WHICH SOLVES THE LEAST SQUARES PROBLEM
!
!                  A*X = B  SUBJECT TO  X >= 0
!
!     A(),MDA,M,N
!            MDA IS THE FIRST DIMENSIONING PARAMETER FOR THE ARRAY,A().
!            ON ENTRY A()  CONTAINS THE M BY N MATRIX,A.
!            ON EXIT A() CONTAINS THE PRODUCT Q*A,
!            WHERE Q IS AN M BY M ORTHOGONAL MATRIX GENERATED
!            IMPLICITLY BY THIS SUBROUTINE.
!            EITHER M>=N OR M<N IS PERMISSIBLE.
!            THERE IS NO RESTRICTION ON THE RANK OF A.
!     B()    ON ENTRY B() CONTAINS THE M-VECTOR, B.
!            ON EXIT B() CONTAINS Q*B.
!     X()    ON ENTRY X() NEED NOT BE INITIALIZED.
!            ON EXIT X() WILL CONTAIN THE SOLUTION VECTOR.
!     RNORM  ON EXIT RNORM CONTAINS THE EUCLIDEAN NORM OF THE
!            RESIDUAL VECTOR.
!     W()    AN N-ARRAY OF WORKING SPACE.
!            ON EXIT W() WILL CONTAIN THE DUAL SOLUTION VECTOR.
!            W WILL SATISFY W(I)=0 FOR ALL I IN SET P
!            AND W(I)<=0 FOR ALL I IN SET Z
!     Z()    AN M-ARRAY OF WORKING SPACE.
!     INDEX()AN INTEGER WORKING ARRAY OF LENGTH AT LEAST N.
!            ON EXIT THE CONTENTS OF THIS ARRAY DEFINE THE SETS
!            P AND Z AS FOLLOWS:
!            INDEX(1)    THRU INDEX(NSETP) = SET P.
!            INDEX(IZ1)  THRU INDEX (IZ2)  = SET Z.
!            IZ1=NSETP + 1 = NPP1, IZ2=N.
!     MODE   THIS IS A SUCCESS-FAILURE FLAG WITH THE FOLLOWING MEANING:
!            1    THE SOLUTION HAS BEEN COMPUTED SUCCESSFULLY.
!            2    THE DIMENSIONS OF THE PROBLEM ARE WRONG,
!                 EITHER M <= 0 OR N <= 0.
!            3    ITERATION COUNT EXCEEDED, MORE THAN 3*N ITERATIONS.
!
!     revised          Dieter Kraft, March 1983

    SUBROUTINE NNLS(A,Mda,M,N,B,X,Rnorm,W,Z,Index,Mode)
    IMPLICIT NONE

      INTEGER :: i , ii , ip , iter , itmax , iz , izmax , iz1 , iz2 , j , &
                 jj , jz , k , l , M , Mda , Mode , N , npp1 , nsetp , &
                 Index(N)

      real(wp) :: A(Mda,N) , B(M) , X(N) , W(N) , Z(M) , asave , &
                  wmax , alpha , c , s , t , u , v , up , Rnorm , unorm

      real(wp),parameter :: zero   = 0.0_wp
      real(wp),parameter :: one    = 1.0_wp
      real(wp),parameter :: factor = 1.0e-2_wp

      Mode = 2
      IF ( M>0 .AND. N>0 ) THEN
         Mode = 1
         iter = 0
         itmax = 3*N

! STEP ONE (INITIALIZE)

         DO i = 1 , N
            Index(i) = i
         ENDDO
         iz1 = 1
         iz2 = N
         nsetp = 0
         npp1 = 1
         X(1) = zero
         CALL DCOPY(N,X(1),0,X,1)

! STEP TWO (COMPUTE DUAL VARIABLES)
! .....ENTRY LOOP A

 50      IF ( iz1<=iz2 .AND. nsetp<M ) THEN
            DO iz = iz1 , iz2
               j = Index(iz)
               W(j) = DDOT(M-nsetp,A(npp1,j),1,B(npp1),1)
            ENDDO

! STEP THREE (TEST DUAL VARIABLES)

 60         wmax = zero
            DO iz = iz1 , iz2
               j = Index(iz)
               IF ( W(j)>wmax ) THEN
                  wmax = W(j)
                  izmax = iz
               ENDIF
            ENDDO

! .....EXIT LOOP A

            IF ( wmax>zero ) THEN
               iz = izmax
               j = Index(iz)

! STEP FOUR (TEST INDEX J FOR LINEAR DEPENDENCY)

               asave = A(npp1,j)
               CALL H12(1,npp1,npp1+1,M,A(1,j),1,up,Z,1,1,0)
               unorm = DNRM2(nsetp,A(1,j),1)
               t = factor*ABS(A(npp1,j))
               IF ( DIFF(unorm+t,unorm)>zero ) THEN
                  CALL DCOPY(M,B,1,Z,1)
                  CALL H12(2,npp1,npp1+1,M,A(1,j),1,up,Z,1,1,1)
                  IF ( Z(npp1)/A(npp1,j)>zero ) THEN
! STEP FIVE (ADD COLUMN)

                     CALL DCOPY(M,Z,1,B,1)
                     Index(iz) = Index(iz1)
                     Index(iz1) = j
                     iz1 = iz1 + 1
                     nsetp = npp1
                     npp1 = npp1 + 1
                     DO jz = iz1 , iz2
                        jj = Index(jz)
                        CALL H12(2,nsetp,npp1,M,A(1,j),1,up,A(1,jj),1,Mda,1)
                     ENDDO
                     k = MIN(npp1,Mda)
                     W(j) = zero
                     CALL DCOPY(M-nsetp,W(j),0,A(k,j),1)

! STEP SIX (SOLVE LEAST SQUARES SUB-PROBLEM)
! .....ENTRY LOOP B

 62                  DO ip = nsetp , 1 , -1
                        IF ( ip/=nsetp ) CALL DAXPY(ip,-Z(ip+1),A(1,jj),1,Z,1)
                        jj = Index(ip)
                        Z(ip) = Z(ip)/A(ip,jj)
                     ENDDO
                     iter = iter + 1
                     IF ( iter<=itmax ) THEN
! STEP SEVEN TO TEN (STEP LENGTH ALGORITHM)

                        alpha = one
                        jj = 0
                        DO ip = 1 , nsetp
                           IF ( Z(ip)<=zero ) THEN
                              l = Index(ip)
                              t = -X(l)/(Z(ip)-X(l))
                              IF ( alpha>=t ) THEN
                                 alpha = t
                                 jj = ip
                              ENDIF
                           ENDIF
                        ENDDO
                        DO ip = 1 , nsetp
                           l = Index(ip)
                           X(l) = (one-alpha)*X(l) + alpha*Z(ip)
                        ENDDO

! .....EXIT LOOP B

                        IF ( jj==0 ) GOTO 50

! STEP ELEVEN (DELETE COLUMN)

                        i = Index(jj)
 64                     X(i) = zero
                        jj = jj + 1
                        DO j = jj , nsetp
                           ii = Index(j)
                           Index(j-1) = ii
                           CALL DSROTG(A(j-1,ii),A(j,ii),c,s)
                           t = A(j-1,ii)
                           CALL DSROT(N,A(j-1,1),Mda,A(j,1),Mda,c,s)
                           A(j-1,ii) = t
                           A(j,ii) = zero
                           CALL DSROT(1,B(j-1),1,B(j),1,c,s)
                        ENDDO
                        npp1 = nsetp
                        nsetp = nsetp - 1
                        iz1 = iz1 - 1
                        Index(iz1) = i
                        IF ( nsetp<=0 ) THEN
                           Mode = 3
                           GOTO 100
                        ELSE
                           DO jj = 1 , nsetp
                              i = Index(jj)
                              IF ( X(i)<=zero ) GOTO 64
                           ENDDO
                           CALL DCOPY(M,B,1,Z,1)
                           GOTO 62
                        ENDIF
                     ELSE
                        Mode = 3
                        GOTO 100
                     ENDIF
                  ENDIF
               ENDIF
               A(npp1,j) = asave
               W(j) = zero
               GOTO 60
            ENDIF
         ENDIF
! STEP TWELVE (SOLUTION)

 100     k = MIN(npp1,M)
         Rnorm = DNRM2(M-nsetp,B(k),1)
         IF ( npp1>M ) THEN
            W(1) = zero
            CALL DCOPY(N,W(1),0,W,1)
         ENDIF
      ENDIF

      END SUBROUTINE NNLS
!*******************************************************************************

!*******************************************************************************
!>
!     RANK-DEFICIENT LEAST SQUARES ALGORITHM AS DESCRIBED IN:
!     C.L.LAWSON AND R.J.HANSON, JET PROPULSION LABORATORY, 1973 JUN 12
!     TO APPEAR IN 'SOLVING LEAST SQUARES PROBLEMS', PRENTICE-HALL, 1974
!
!     A(*,*),MDA,M,N   THE ARRAY A INITIALLY CONTAINS THE M x N MATRIX A
!                      OF THE LEAST SQUARES PROBLEM AX = B.
!                      THE FIRST DIMENSIONING PARAMETER MDA MUST SATISFY
!                      MDA >= M. EITHER M >= N OR M < N IS PERMITTED.
!                      THERE IS NO RESTRICTION ON THE RANK OF A.
!                      THE MATRIX A WILL BE MODIFIED BY THE SUBROUTINE.
!     B(*,*),MDB,NB    IF NB = 0 THE SUBROUTINE WILL MAKE NO REFERENCE
!                      TO THE ARRAY B. IF NB > 0 THE ARRAY B() MUST
!                      INITIALLY CONTAIN THE M x NB MATRIX B  OF THE
!                      THE LEAST SQUARES PROBLEM AX = B AND ON RETURN
!                      THE ARRAY B() WILL CONTAIN THE N x NB SOLUTION X.
!                      IF NB>1 THE ARRAY B() MUST BE DOUBLE SUBSCRIPTED
!                      WITH FIRST DIMENSIONING PARAMETER MDB>=MAX(M,N),
!                      IF NB=1 THE ARRAY B() MAY BE EITHER SINGLE OR
!                      DOUBLE SUBSCRIPTED.
!     TAU              ABSOLUTE TOLERANCE PARAMETER FOR PSEUDORANK
!                      DETERMINATION, PROVIDED BY THE USER.
!     KRANK            PSEUDORANK OF A, SET BY THE SUBROUTINE.
!     RNORM            ON EXIT, RNORM(J) WILL CONTAIN THE EUCLIDIAN
!                      NORM OF THE RESIDUAL VECTOR FOR THE PROBLEM
!                      DEFINED BY THE J-TH COLUMN VECTOR OF THE ARRAY B.
!     H(), G()         ARRAYS OF WORKING SPACE OF LENGTH >= N.
!     IP()             INTEGER ARRAY OF WORKING SPACE OF LENGTH >= N
!                      RECORDING PERMUTATION INDICES OF COLUMN VECTORS

    SUBROUTINE HFTI(A,Mda,M,N,B,Mdb,Nb,Tau,Krank,Rnorm,H,G,Ip)
    IMPLICIT NONE

    INTEGER :: i , j , jb , k , kp1 , Krank , l , ldiag , lmax , M , &
               Mda , Mdb , N , Nb , Ip(N)
    real(wp) :: A(Mda,N) , B(Mdb,Nb) , H(N) , G(N) , Rnorm(Nb) , &
                Tau , hmax , tmp , &
                u , v

    real(wp),parameter :: zero   = 0.0_wp
    real(wp),parameter :: factor = 1.0e-3_wp

    k = 0
    ldiag = MIN(M,N)
    IF ( ldiag<=0 ) THEN
       Krank = k
       return
    ELSE

       ! COMPUTE LMAX

       DO j = 1 , ldiag
          IF ( j/=1 ) THEN
             lmax = j
             DO l = j , N
                H(l) = H(l) - A(j-1,l)**2
                IF ( H(l)>H(lmax) ) lmax = l
             ENDDO
             IF ( DIFF(hmax+factor*H(lmax),hmax)>zero ) GOTO 20
          ENDIF
          lmax = j
          DO l = j , N
             H(l) = zero
             DO i = j , M
                H(l) = H(l) + A(i,l)**2
             ENDDO
             IF ( H(l)>H(lmax) ) lmax = l
          ENDDO
          hmax = H(lmax)

          ! COLUMN INTERCHANGES IF NEEDED

20        Ip(j) = lmax
          IF ( Ip(j)/=j ) THEN
             DO i = 1 , M
                tmp = A(i,j)
                A(i,j) = A(i,lmax)
                A(i,lmax) = tmp
             ENDDO
             H(lmax) = H(j)
          ENDIF

          ! J-TH TRANSFORMATION AND APPLICATION TO A AND B

          i = MIN(j+1,N)
          CALL H12(1,j,j+1,M,A(1,j),1,H(j),A(1,i),1,Mda,N-j)
          CALL H12(2,j,j+1,M,A(1,j),1,H(j),B,1,Mdb,Nb)
       ENDDO

       !determine pseudorank:

       do j=1,ldiag
          if (abs(a(j,j))<=tau) exit
       end do
       k=j-1
       kp1=j

    END IF

    ! NORM OF RESIDUALS

    DO jb = 1 , Nb
       Rnorm(jb) = DNRM2(M-k,B(kp1,jb),1)
    ENDDO
    IF ( k>0 ) THEN
       IF ( k/=N ) THEN
          ! HOUSEHOLDER DECOMPOSITION OF FIRST K ROWS
          DO i = k , 1 , -1
             CALL H12(1,i,kp1,N,A(i,1),Mda,G(i),A,Mda,1,i-1)
          ENDDO
       ENDIF
       DO jb = 1 , Nb

          ! SOLVE K*K TRIANGULAR SYSTEM

          DO i = k , 1 , -1
             j = MIN(i+1,N)
             B(i,jb) = (B(i,jb)-DDOT(k-i,A(i,j),Mda,B(j,jb),1))/A(i,i)
          ENDDO

          ! COMPLETE SOLUTION VECTOR

          IF ( k/=N ) THEN
             DO j = kp1 , N
                B(j,jb) = zero
             ENDDO
             DO i = 1 , k
                CALL H12(2,i,kp1,N,A(i,1),Mda,G(i),B(1,jb),1,Mdb,1)
             ENDDO
          ENDIF

          ! REORDER SOLUTION ACCORDING TO PREVIOUS COLUMN INTERCHANGES

          DO j = ldiag , 1 , -1
             IF ( Ip(j)/=j ) THEN
                l = Ip(j)
                tmp = B(l,jb)
                B(l,jb) = B(j,jb)
                B(j,jb) = tmp
             ENDIF
          ENDDO
       ENDDO
    ELSE
       DO jb = 1 , Nb
          DO i = 1 , N
             B(i,jb) = zero
          ENDDO
       ENDDO
    ENDIF
    Krank = k
    END SUBROUTINE HFTI
!*******************************************************************************

!*******************************************************************************
!>
!     C.L.LAWSON AND R.J.HANSON, JET PROPULSION LABORATORY, 1973 JUN 12
!     TO APPEAR IN 'SOLVING LEAST SQUARES PROBLEMS', PRENTICE-HALL, 1974
!
!     CONSTRUCTION AND/OR APPLICATION OF A SINGLE
!     HOUSEHOLDER TRANSFORMATION  Q = I + U*(U**T)/B
!
!     MODE    = 1 OR 2   TO SELECT ALGORITHM  H1  OR  H2 .
!     LPIVOT IS THE INDEX OF THE PIVOT ELEMENT.
!     L1,M   IF L1 <= M   THE TRANSFORMATION WILL BE CONSTRUCTED TO
!            ZERO ELEMENTS INDEXED FROM L1 THROUGH M.
!            IF L1 > M THE SUBROUTINE DOES AN IDENTITY TRANSFORMATION.
!     U(),IUE,UP
!            ON ENTRY TO H1 U() STORES THE PIVOT VECTOR.
!            IUE IS THE STORAGE INCREMENT BETWEEN ELEMENTS.
!            ON EXIT FROM H1 U() AND UP STORE QUANTITIES DEFINING
!            THE VECTOR U OF THE HOUSEHOLDER TRANSFORMATION.
!            ON ENTRY TO H2 U() AND UP
!            SHOULD STORE QUANTITIES PREVIOUSLY COMPUTED BY H1.
!            THESE WILL NOT BE MODIFIED BY H2.
!     C()    ON ENTRY TO H1 OR H2 C() STORES A MATRIX WHICH WILL BE
!            REGARDED AS A SET OF VECTORS TO WHICH THE HOUSEHOLDER
!            TRANSFORMATION IS TO BE APPLIED.
!            ON EXIT C() STORES THE SET OF TRANSFORMED VECTORS.
!     ICE    STORAGE INCREMENT BETWEEN ELEMENTS OF VECTORS IN C().
!     ICV    STORAGE INCREMENT BETWEEN VECTORS IN C().
!     NCV    NUMBER OF VECTORS IN C() TO BE TRANSFORMED.
!            IF NCV <= 0 NO OPERATIONS WILL BE DONE ON C().

    SUBROUTINE H12(Mode,Lpivot,L1,M,U,Iue,Up,C,Ice,Icv,Ncv)
    IMPLICIT NONE

      INTEGER :: incr , Ice , Icv , Iue , Lpivot , L1 , Mode , Ncv
      INTEGER :: i , i2 , i3 , i4 , j , M
      real(wp) :: U , Up , C , cl , clinv , b , sm

      DIMENSION U(Iue,*) , C(*)

      real(wp),parameter :: one  = 1.0_wp
      real(wp),parameter :: zero = 0.0_wp

      IF ( 0<Lpivot .AND. Lpivot<L1 .AND. L1<=M ) THEN
         cl = ABS(U(1,Lpivot))
         IF ( Mode/=2 ) THEN

             ! ****** CONSTRUCT THE TRANSFORMATION ******

            DO j = L1 , M
               sm = ABS(U(1,j))
               cl = MAX(sm,cl)
            ENDDO
            IF ( cl<=zero ) return
            clinv = one/cl
            sm = (U(1,Lpivot)*clinv)**2
            DO j = L1 , M
               sm = sm + (U(1,j)*clinv)**2
            ENDDO
            cl = cl*SQRT(sm)
            IF ( U(1,Lpivot)>zero ) cl = -cl
            Up = U(1,Lpivot) - cl
            U(1,Lpivot) = cl

            ! ****** APPLY THE TRANSFORMATION  I+U*(U**T)/B  TO C ******

         ELSEIF ( cl<=zero ) THEN
            return
         ENDIF
         IF ( Ncv>0 ) THEN
            b = Up*U(1,Lpivot)
            IF ( b<zero ) THEN
               b = one/b
               i2 = 1 - Icv + Ice*(Lpivot-1)
               incr = Ice*(L1-Lpivot)
               DO j = 1 , Ncv
                  i2 = i2 + Icv
                  i3 = i2 + incr
                  i4 = i3
                  sm = C(i2)*Up
                  DO i = L1 , M
                     sm = sm + C(i3)*U(1,i)
                     i3 = i3 + Ice
                  ENDDO
                  IF ( sm/=zero ) THEN
                     sm = sm*b
                     C(i2) = C(i2) + sm*Up
                     DO i = L1 , M
                        C(i4) = C(i4) + sm*U(1,i)
                        i4 = i4 + Ice
                     ENDDO
                  ENDIF
               ENDDO
            ENDIF
         ENDIF
      ENDIF

      END SUBROUTINE H12
!*******************************************************************************

!*******************************************************************************
!>
!   LDL     LDL' - RANK-ONE - UPDATE
!
!   PURPOSE:
!           UPDATES THE LDL' FACTORS OF MATRIX A BY RANK-ONE MATRIX
!           SIGMA*Z*Z'
!
!   INPUT ARGUMENTS: (* MEANS PARAMETERS ARE CHANGED DURING EXECUTION)
!     N     : ORDER OF THE COEFFICIENT MATRIX A
!   * A     : POSITIVE DEFINITE MATRIX OF DIMENSION N;
!             ONLY THE LOWER TRIANGLE IS USED AND IS STORED COLUMN BY
!             COLUMN AS ONE DIMENSIONAL ARRAY OF DIMENSION N*(N+1)/2.
!   * Z     : VECTOR OF DIMENSION N OF UPDATING ELEMENTS
!     SIGMA : SCALAR FACTOR BY WHICH THE MODIFYING DYADE Z*Z' IS
!             MULTIPLIED
!
!   OUTPUT ARGUMENTS:
!     A     : UPDATED LDL' FACTORS
!
!   WORKING ARRAY:
!     W     : VECTOR OP DIMENSION N (USED ONLY IF SIGMA < ZERO)
!
!   METHOD:
!     THAT OF FLETCHER AND POWELL AS DESCRIBED IN :
!     FLETCHER,R.,(1974) ON THE MODIFICATION OF LDL' FACTORIZATION.
!     POWELL,M.J.D.      MATH.COMPUTATION 28, 1067-1078.
!
!   IMPLEMENTED BY:
!     KRAFT,D., DFVLR - INSTITUT FUER DYNAMIK DER FLUGSYSTEME
!               D-8031  OBERPFAFFENHOFEN
!
!   STATUS: 15. JANUARY 1980

    SUBROUTINE LDL(N,A,Z,Sigma,W)
    IMPLICIT NONE

      INTEGER :: i , ij , j , N
      real(wp) :: A(*) , t , v , W(*) , Z(*) , u , tp , &
                       beta , alpha , delta , gamma , Sigma

      real(wp),parameter :: zero   = 0.0_wp
      real(wp),parameter :: one    = 1.0_wp
      real(wp),parameter :: four   = 4.0_wp
      real(wp),parameter :: epmach = epsilon(1.0_wp)

      IF ( Sigma/=zero ) THEN
         ij = 1
         t = one/Sigma
         IF ( Sigma<=zero ) THEN
            ! PREPARE NEGATIVE UPDATE
            DO i = 1 , N
               W(i) = Z(i)
            ENDDO
            DO i = 1 , N
               v = W(i)
               t = t + v*v/A(ij)
               DO j = i + 1 , N
                  ij = ij + 1
                  W(j) = W(j) - v*A(ij)
               ENDDO
               ij = ij + 1
            ENDDO
            IF ( t>=zero ) t = epmach/Sigma
            DO i = 1 , N
               j = N + 1 - i
               ij = ij - i
               u = W(j)
               W(j) = t
               t = t - u*u/A(ij)
            ENDDO
         ENDIF
         ! HERE UPDATING BEGINS
         DO i = 1 , N
            v = Z(i)
            delta = v/A(ij)
            IF ( Sigma<zero ) tp = W(i)
            IF ( Sigma>zero ) tp = t + delta*v
            alpha = tp/t
            A(ij) = alpha*A(ij)
            IF ( i==N ) return
            beta = delta/tp
            IF ( alpha>four ) THEN
               gamma = t/tp
               DO j = i + 1 , N
                  ij = ij + 1
                  u = A(ij)
                  A(ij) = gamma*u + beta*Z(j)
                  Z(j) = Z(j) - v*u
               ENDDO
            ELSE
               DO j = i + 1 , N
                  ij = ij + 1
                  Z(j) = Z(j) - v*A(ij)
                  A(ij) = A(ij) + beta*Z(j)
               ENDDO
            ENDIF
            ij = ij + 1
            t = tp
         ENDDO
      ENDIF

      END SUBROUTINE LDL
!*******************************************************************************

!*******************************************************************************
!>
!   LINMIN  LINESEARCH WITHOUT DERIVATIVES
!   (used if EXACT = 1)
!
!   PURPOSE:
!
!  TO FIND THE ARGUMENT LINMIN WHERE THE FUNCTION F TAKES IT'S MINIMUM
!  ON THE INTERVAL AX, BX.
!  COMBINATION OF GOLDEN SECTION AND SUCCESSIVE QUADRATIC INTERPOLATION.
!
!   INPUT ARGUMENTS: (* MEANS PARAMETERS ARE CHANGED DURING EXECUTION)
!
! *MODE   SEE OUTPUT ARGUMENTS
!  AX     LEFT ENDPOINT OF INITIAL INTERVAL
!  BX     RIGHT ENDPOINT OF INITIAL INTERVAL
!  F      FUNCTION VALUE AT LINMIN WHICH IS TO BE BROUGHT IN BY
!         REVERSE COMMUNICATION CONTROLLED BY MODE
!  TOL    DESIRED LENGTH OF INTERVAL OF UNCERTAINTY OF FINAL RESULT
!
!   OUTPUT ARGUMENTS:
!
!  LINMIN ABSCISSA APPROXIMATING THE POINT WHERE F ATTAINS A MINIMUM
!  MODE   CONTROLS REVERSE COMMUNICATION
!         MUST BE SET TO 0 INITIALLY, RETURNS WITH INTERMEDIATE
!         VALUES 1 AND 2 WHICH MUST NOT BE CHANGED BY THE USER,
!         ENDS WITH CONVERGENCE WITH VALUE 3.
!
!   METHOD:
!
!  THIS FUNCTION SUBPROGRAM IS A SLIGHTLY MODIFIED VERSION OF THE
!  ALGOL 60 PROCEDURE LOCALMIN GIVEN IN
!  R.P. BRENT: ALGORITHMS FOR MINIMIZATION WITHOUT DERIVATIVES,
!              PRENTICE-HALL (1973).
!
!   IMPLEMENTED BY:
!
!     KRAFT, D., DFVLR - INSTITUT FUER DYNAMIK DER FLUGSYSTEME
!                D-8031  OBERPFAFFENHOFEN
!
!   STATUS: 31. AUGUST  1984

    real(wp) FUNCTION LINMIN(Mode,Ax,Bx,F,Tol)
    IMPLICIT NONE

      INTEGER :: Mode
      real(wp) :: F , Tol , a , b , d , e , p , q , r , u , v ,&
                  w , x , m , fu , fv , fw , fx , tol1 , &
                  tol2 , Ax , Bx

      real(wp),parameter :: c    = (3.0_wp-sqrt(5.0_wp))/2.0_wp  !! golden section ratio = `0.381966011`
      real(wp),parameter :: eps  = sqrt(epsilon(1.0_wp))         !! square - root of machine precision
      real(wp),parameter :: zero = 0.0_wp

      IF ( Mode==1 ) THEN

          !  MAIN LOOP STARTS HERE

         fx = F
         fv = fx
         fw = fv

      ELSEIF ( Mode==2 ) THEN

         fu = F
         !  UPDATE A, B, V, W, AND X
         IF ( fu>fx ) THEN
            IF ( u<x ) a = u
            IF ( u>=x ) b = u
            IF ( fu<=fw .OR. w==x ) THEN
               v = w
               fv = fw
               w = u
               fw = fu
            ELSEIF ( fu<=fv .OR. v==x .OR. v==w ) THEN
               v = u
               fv = fu
            ENDIF
         ELSE
            IF ( u>=x ) a = x
            IF ( u<x ) b = x
            v = w
            fv = fw
            w = x
            fw = fx
            x = u
            fx = fu
         ENDIF
      ELSE
         !  INITIALIZATION
         a = Ax
         b = Bx
         e = zero
         v = a + c*(b-a)
         w = v
         x = w
         LINMIN = x
         Mode = 1
         return
      ENDIF
      m = 0.5_wp*(a+b)
      tol1 = eps*ABS(x) + Tol
      tol2 = tol1 + tol1

      !  TEST CONVERGENCE

      IF ( ABS(x-m)<=tol2-0.5_wp*(b-a) ) THEN
         !  END OF MAIN LOOP
         LINMIN = x
         Mode = 3
      ELSE
         r = zero
         q = r
         p = q
         IF ( ABS(e)>tol1 ) THEN
            !  FIT PARABOLA
            r = (x-w)*(fx-fv)
            q = (x-v)*(fx-fw)
            p = (x-v)*q - (x-w)*r
            q = q - r
            q = q + q
            IF ( q>zero ) p = -p
            IF ( q<zero ) q = -q
            r = e
            e = d
         ENDIF

         !  IS PARABOLA ACCEPTABLE
         IF ( ABS(p)>=0.5_wp*ABS(q*r) .OR. p<=q*(a-x) .OR. p>=q*(b-x) ) THEN
            !  GOLDEN SECTION STEP
            IF ( x>=m ) e = a - x
            IF ( x<m ) e = b - x
            d = c*e
         ELSE
            !  PARABOLIC INTERPOLATION STEP
            d = p/q
            !  F MUST NOT BE EVALUATED TOO CLOSE TO A OR B
            IF ( u-a<tol2 ) d = SIGN(tol1,m-x)
            IF ( b-u<tol2 ) d = SIGN(tol1,m-x)
         ENDIF

         !  F MUST NOT BE EVALUATED TOO CLOSE TO X
         IF ( ABS(d)<tol1 ) d = SIGN(tol1,d)
         u = x + d
         LINMIN = u
         Mode = 2

      ENDIF

      END FUNCTION LINMIN
!*******************************************************************************

!*******************************************************************************
!>
!  Enforce the bound constraints on x.

    subroutine enforce_bounds(x,xl,xu)

    implicit none

    real(wp),dimension(:),intent(inout) :: x   !! optimization variable vector
    real(wp),dimension(:),intent(in)    :: xl  !! lower bounds (must be same dimension as `x`)
    real(wp),dimension(:),intent(in)    :: xu  !! upper bounds (must be same dimension as `x`)

    where (x<xl)
        x = xl
    elsewhere (x>xu)
        x = xu
    end where

    end subroutine enforce_bounds
!*******************************************************************************

!*******************************************************************************
    end module slsqp_module
!*******************************************************************************