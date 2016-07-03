module slsqp_interface
  use iso_c_binding, only: c_double, c_int
  use slsqp_module, only: slsqp
  implicit none
  contains
  subroutine c_slsqp(x, n, m, a, b, c) bind(c)
    real(c_double), intent(in) :: x
    integer(c_int), intent(in) ::  n, m
    real(c_double), dimension(n), intent(in) :: a
    real(c_double), dimension(m), intent(in) :: b
    real(c_double), dimension(n, m), intent(out) :: c
    call slsqp(x, n, m, a, b, c)
  end subroutine
  end module
