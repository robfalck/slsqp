from __future__ import print_function, division

from distutils.core import setup
from distutils.extension import Extension
from Cython.Distutils import build_ext
# This line only needed if building with NumPy in Cython file.
from numpy import get_include
import os
import os.path
import shutil

# compile the fortran modules without linking
fortran_mod_comp = 'gfortran slsqp.f90 -c -o slsqp.o -O3 -fPIC'
print(fortran_mod_comp)
os.system(fortran_mod_comp)

fortran_mod_comp = 'gfortran slsqp_kinds.f90 -c -o slsqp_kinds.o -O3 -fPIC'
print(fortran_mod_comp)
os.system(fortran_mod_comp)

shared_obj_comp = 'gfortran slsqp_interface.f90 -c -o slsqp_interface.o -O3 -fPIC'
print(shared_obj_comp)
os.system(shared_obj_comp)

parent_dir, _ = os.path.split(os.getcwd())
src_dir = os.path.join(parent_dir,'src')
lib_dir = os.path.join(parent_dir,'lib')

print('done with setup')


src_dir = os.path.join(parent_dir,'src')
src_files = ['slsqp_core.f90', 'slsqp_kinds.f90', 'slsqp_module.f90', 'slsqp_support.f90']
slsqp_objs = [ file.replace('.f90','.o') for file in src_files ]

#slsqp_objs = []

# for file in src_files:
#     shutil.copy(os.path.join(src_dir,file),os.path.join(os.getcwd(),file))
#     obj_file = file.replace('.f90','.o')
#     os.system('gfortran {0} -c -o {1} -O3 -fPIC'.format(file,obj_file))
#     slsqp_objs.append(obj_file)

#slsqp_objs  = ['slsqp_core.o', 'slsqp_kinds.o', 'slsqp_module.o', 'slsqp_support.o']

#fobjs = [ '{0}/{1}'.format(lib_dir, file) for file in slsqp_objs ]

#fobjs = []

#print(fobjs)

ext_modules = [Extension(# module name:
                         'slsqp',
                         # source file:
                         ['slsqp.pyx'],
                         # other compile args for gcc
                         extra_compile_args=['-fPIC', '-O3'],
                         libraries=['gfortran'],
                         # other files to link to
                         extra_link_args=['slsqp.o', 'slsqp_interface.o'] + slsqp_objs)]

setup(name = 'slsqp',
      cmdclass = {'build_ext': build_ext},
      # Needed if building with NumPy.
      # This includes the NumPy headers when compiling.
      include_dirs = [get_include()],
      ext_modules = ext_modules)
