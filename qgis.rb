require 'formula'

def grass?
  ARGV.include? "--with-grass"
end

def postgis?
  ARGV.include? "--with-postgis"
end

def py_version
  `python -c 'import sys;print sys.version[:3]'`.chomp
end

# QWT 6.x has an insane build system---can't use the framework files it
# produces as they don't link properly. So, we use an internal static brew of
# QWT 5.2.2.
class Qwt52 < Formula
  url 'http://sourceforge.net/projects/qwt/files/qwt/5.2.2/qwt-5.2.2.tar.bz2'
  homepage 'http://qwt.sourceforge.net'
  md5 '70d77e4008a6cc86763737f0f24726ca'
end

# QGIS requires a newer version of bison than OS X provides.
class Bison < Formula
  url 'http://ftpmirror.gnu.org/bison/bison-2.5.tar.bz2'
  homepage 'http://www.gnu.org/software/bison/'
  md5 '9dba20116b13fc61a0846b0058fbe004'
end

class Qgis < Formula
  homepage 'http://www.qgis.org'
  url 'http://qgis.org/downloads/qgis-1.7.4.tar.bz2'
  md5 'ad6e2bd8c5eb0c486939c420af5d8c44'

  head 'https://github.com/qgis/Quantum-GIS.git', :branch => 'master'

  def options
    [
      ['--with-grass', 'Build support for GRASS GIS.'],
      ['--with-postgis', 'Build support for PostGIS databases.']
    ]
  end

  depends_on 'cmake' => :build

  depends_on 'gsl'
  depends_on 'PyQt'
  depends_on 'gdal'
  depends_on 'spatialindex' if ARGV.build_head?

  depends_on 'grass' if grass?
  depends_on 'gettext' if grass? # For libintl

  depends_on 'postgis' if postgis?

  fails_with :clang do
    build 318
    cause 'Cant resolve std::ostrem<< in SpatialIndex.h'
  end

  def install
    internal_qwt = Pathname.new(Dir.getwd) + 'qwt52'
    internal_bison = Pathname.new(Dir.getwd) + 'bison'

    Bison.new.brew do
      system "./configure", "--prefix=#{internal_bison}", "--disable-debug", "--disable-dependency-tracking"
      system 'make install'
    end

    Qwt52.new.brew do
      inreplace 'qwtconfig.pri' do |s|
        # change_make_var won't work because there are leading spaces
        s.gsub! /^\s*INSTALLBASE\s*=(.*)$/, "INSTALLBASE=#{internal_qwt}"
        # Removing the `QwtDll` config option will cause Qwt to build as a
        # satic library. We could build dynamic, but we would need to hit the
        # results with `install_name_tool` to make sure the paths are right. As
        # the QGIS main executable seems to be the only thing that links
        # against this, I'm keeping it simple with a static lib.
        s.gsub! /^(\s*CONFIG.*QwtDll)$/, ''
      end

      system 'qmake -spec macx-g++ -config release'
      system 'make install'
    end

    args = std_cmake_args.concat %W[
      -DQWT_INCLUDE_DIR=#{internal_qwt}/include
      -DQWT_LIBRARY=#{internal_qwt}/lib/libqwt.a
      -DBISON_EXECUTABLE=#{internal_bison}/bin/bison
    ]

    # Some test programs invoke binaries during construction that have
    # incorrect library load paths---this causes the builds to fail.
    #
    # Set bundling level back to 0 (the default in all versions prior to 1.8.0)
    # so that no time and energy is wasted copying the Qt frameworks into QGIS.
    args.concat %W[
      -DENABLE_TESTS=NO
      -DQGIS_MACAPP_BUNDLE=0
      -DQGIS_MACAPP_DEV_PREFIX='#{lib}'
      -DQGIS_MACAPP_INSTALL_DEV=YES
    ] if ARGV.build_head?

    ARGV.filter_for_dependencies do
      # Ensure --HEAD flags get stripped.
      grass = Formula.factory 'grass'
      gettext = Formula.factory 'gettext'
      args << "-DGRASS_PREFIX='#{Dir[grass.prefix + 'grass-*']}'"
      # So that `libintl.h` can be found
      ENV.append 'CXXFLAGS', "-I'#{gettext.include}'"
    end if grass?

    Dir.mkdir 'build'
    Dir.chdir 'build' do
      system 'cmake', '..', *args
      system 'make install'
    end

    # Symlink the PyQGIS Python module somewhere convienant for users to put on
    # their PYTHONPATH
    py_lib = lib + "python#{py_version}/site-packages"
    qgis_modules = prefix + 'QGIS.app/Contents/Resources/python/qgis'

    py_lib.mkpath
    ln_s qgis_modules, py_lib + 'qgis'

    # Create script to launch QGIS app
    (bin + 'qgis').write <<-EOS.undent
      #!/bin/sh

      # Ensure Python modules can be found when QGIS is running.
      env PYTHONPATH='#{HOMEBREW_PREFIX}/lib/python#{py_version}/site-packages':$PYTHONPATH\\
        open #{prefix}/QGIS.app
    EOS
  end

  def caveats; <<-EOS.undent
    QGIS has been built as an application bundle. To make it easily available, a
    wrapper script has been written that launches the app with environment
    variables set so that Python modules will be functional:

      qgis

    You may also symlink QGIS.app into ~/Applications:
      brew linkapps
      mkdir -p #{ENV['HOME']}/.MacOSX
      defaults write #{ENV['HOME']}/.MacOSX/environment.plist PYTHONPATH -string "#{HOMEBREW_PREFIX}/lib/#{which_python}/site-packages"

    You will need to log out and log in again to make environment.plist effective.

    The QGIS python modules have been symlinked to:

      #{HOMEBREW_PREFIX}/lib/python#{py_version}/site-packages

    If you are interested in PyQGIS development and are not using the Homebrew
    Python formula, then you will need to ensure this directory is on your
    PYTHONPATH.
    EOS
  end
end
