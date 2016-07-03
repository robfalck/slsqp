from distutils.core import setup
from distutils.extension import Extension
from Cython.Distutils import build_ext
# This line only needed if building with NumPy in Cython file.
from numpy import get_include
from os import system

# compile the fortran modules without linking
fortran_mod_comp = 'gfortran slsqp.f90 -c -o slsqp.o -O3 -fPIC'
print fortran_mod_comp
system(fortran_mod_comp)
shared_obj_comp = 'gfortran slsqp_interface.f90 -c -o slsqp_interface.o -O3 -fPIC'
print shared_obj_comp
system(shared_obj_comp)

ext_modules = [Extension(# module name:
                         'slsqp',
                         # source file:
                         ['slsqp.pyx'],
                         # other compile args for gcc
                         extra_compile_args=['-fPIC', '-O3'],
                         # other files to link to
                         extra_link_args=['slsqp.o', 'slsqp_interface.o'])]

setup(name = 'slsqp',
      cmdclass = {'build_ext': build_ext},
      # Needed if building with NumPy.
      # This includes the NumPy headers when compiling.
      include_dirs = [get_include()],
      ext_modules = ext_modules)
