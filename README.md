# AndroidMakefileAnalyzer

# Create .xml for AbiComplianceChecker

```
$ ruby AndroidMakefileScanner.rb ~/work/android/s -m "nativeLib" -o ~/work/android/s/out/target/product/generic -r xml-perlib -v "s" -p ./abi-s -f -e
```


# ABI compatibility checker

## Setup for MacOS

```
$ brew install gcc
$ git clone https://github.com/hidenorly/abi-compliance-checker
( https://github.com/lvc/abi-compliance-checker/pull/119 )
$ abi-compliance-checker -test --gcc-path=/opt/homebrew/bin/gcc-12
```

```.zprofile
export GCC_PATH=/opt/homebrew/bin/gcc-12
```

## How to execute

```
% ruby AndroidMakefileScanner.rb ~/work/android/s -m "nativeLib" -r xml-perlib -e -p abi-s -o ~/work/android/s/out/target/product/generic -f -v s
% ruby AndroidMakefileScanner.rb ~/work/android/t -m "nativeLib" -r xml-perlib -e -p abi-t -o ~/work/android/t/out/target/product/generic -f -v t
% ruby AbiComplianceChecker.rb -o abi abi-s abi-t
```

# TODOs

* [x] Add multi line support in Android.mk
* [x] Add env flatten in Android.mk
* [x] Add call $(call my-dir) support in Android.mk
* [x] Add $(subst support in Android.mk
* [x] Add nested $(subst support in Android.mk
* [x] Add include-path-for support
* [x] Add no header(include) found case support
* [x] Add Android.bp support
  * [] Add defaults: support (super(base attributes) support) e.g. cc_defaults
* [x] Add .so search from Android built out/ with Android.(mk|bp) parse result
* [x] Add generate abi checker comparison output support (xml file per lib)
  * [x] Add stream support with STDOUT
  * [x] Add stream support with file with -p (--reportOutPath) support
  * [x] Add -r xml-perlib support
  * [x] Add --filterOutMatch support
  * [x] Add -v version support
  * [x] Add unsupported cflags removal support
        * [x] Add for gcc
        * [] Add for clang
  * [x] Add concurrent execution
* [x] Add .jar support
* [x] Add .apk support
  * [x] Add LOCAL_DEX_PREOPT
* [x] Add -m based scan (今は-m jarでもapkもsoもscanしているから)
* [x] Add .apex support
* [] Add build.gradle support

* [] Add AbiComplianceChecker
     * [x] Add concurrent execution
     * 
