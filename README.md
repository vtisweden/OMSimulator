# OMSimulator [![License: OSMC-PL](https://img.shields.io/badge/license-OSMC--PL-lightgrey.svg)](OSMC-License.txt)

The OpenModelica FMI & SSP-based co-simulation environment.

## Downloads

OMSimulator can be installed as stand-alone application, as C library to be linked into custom applications, and as python package. OMSimulator is also shipped with the OpenModelica installer, which also includes OMEdit as the graphical editor.

* [OpenModelica](https://openmodelica.org/)
* [Stand-alone package](https://build.openmodelica.org/omsimulator/)
* Python 3.8+: `pip3 install OMSimulator`

## Documentation

The latest documentation is available as [pdf](https://openmodelica.org/doc/OMSimulator/master/OMSimulator.pdf) and [html](https://openmodelica.org/doc/OMSimulator/master/html/) versions.
For OMSimulatorLib a [Doxygen source code documentation](https://openmodelica.org/doc/OMSimulator/master/OMSimulatorLib/) is available as well.

## FMI cross-check results

* https://libraries.openmodelica.org/fmi-crosschecking/OMSimulator/history/

## Dependencies

- [Boost](http://www.boost.org/) (system, filesystem)
- [cmake](http://www.cmake.org)
- [Sphinx](http://www.sphinx-doc.org/en/stable/)
- [readline (if using Lua)](http://git.savannah.gnu.org/cgit/readline.git)
- [3rdParty subproject](https://github.com/OpenModelica/OMSimulator-3rdParty)
  - FMILibrary
  - Lua
  - PugiXML
  - SUNDIALS CVODE
  - SUNDIALS KINSOL
  - CTPL

## Compilation

Note: Make sure to fetch the submodules, e.g., using `git submodule update --init`.

### Linux / MacOS

1. Install libxml2-dev

   ```bash
   sudo apt-get install libxml2-dev
   ```

1. Configure OMSimulator

   ```bash
   cmake -G Ninja -S . -B build
   ```

1. Build OMSimulator

   ```bash
   cmake --build build/ --target install
   ```

### Windows (OMDev mingw)

1. Setup OMDev

   - Checkout OMDev (OpenModelica Development Environment): `git clone https://openmodelica.org/git/OMDev.git`
   - Follow the instructions in `OMDev/INSTALL.txt`

1. Configure OMSimulator

   ```bash
   cmake -G Ninja -S . -B build
   ```

1. Build OMSimulator

   ```bash
   cmake --build build/ --target install

## Test your build

The testsuite of OMSimulator is run on Jenkins for every commit and creating
[test reports](https://test.openmodelica.org/jenkins/job/OMSimulator/job/master/lastSuccessfulBuild/testReport/).
The project is tested for the following OS:
   - linux-arm32
   - linux64 without OMPython
   - cross-compiled mingw64
   - msvc64
   - cross-compiled OSX

In addition the [OpenModelica project](https://github.com/OpenModelica/OpenModelica) has a number of test cases using OMSimulator for FMU simulation that can be find in this [OpenModelica test reports](https://test.openmodelica.org/jenkins/job/OpenModelica/job/master/lastSuccessfulBuild/testReport/).

To verify your build is compiled and installed corrrectly see the following instructions.

### Linux / MacOS / Windows (OMDev mingw)

1. Build test dependencies
   ```bash
   make -C testsuite/ difftool resources
   ```

2. Run partest

   ```bash
   cd testsuite/partest/
   ./runtests.pl -j4
   ```
   Use `-jN` to test with `N` threads.
   To disable TLM tests add `-notlm`, to disable Python tests add `-asan`.

### Windows (Visual Studio)

We currently have no bat-Script to build and test with CMD, so you have to use OMDev mingw shell for the tests.

1. Build test dependencies
   ```bash
   make -C testsuite/ difftool resources
   ```

2. Run partest

   ```bash
   cd testsuite/partest/
   ./runtests.pl -j4 -platform=win
   ```
   Use `-jN` to test with `N` threads.
   To disable TLM tests add `-notlm`, to disable Python tests add `-asan`.
