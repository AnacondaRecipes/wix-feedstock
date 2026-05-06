@echo on
setlocal

REM ============================================================================
REM Stage build helpers and pre-generated MSBuild config.
REM ============================================================================

REM nuget.exe build helper on PATH (never staged into %PREFIX%).
set "PATH=%SRC_DIR%\build_helpers;%PATH%"

REM Drop a msbuild.cmd shim that defers to `dotnet msbuild`. The PBP win-64
REM AMI ships VS2022 BuildTools without the .NET SDK component, so VS's
REM MSBuild can't load Microsoft.NET.Sdk / WorkloadAutoImportPropsLocator.
REM The conda-installed dotnet 8 SDK has the proper resolver pipeline.
echo @"%BUILD_PREFIX%\dotnet\dotnet.exe" msbuild %%* > "%SRC_DIR%\build_helpers\msbuild.cmd"

REM Skip devbuild.cmd's vsdevcmd re-activation. Conda-build already set up
REM MSVC env (VCToolsInstallDir, INCLUDE, LIB) during legacy compiler setup.
set "WixSkipVsDevCmd=1"
set "DOTNET_ROOT=%BUILD_PREFIX%\dotnet"

REM Pre-generate the three files that build_init.cmd's SetBuildNumber.proj
REM would normally produce. SetBuildNumber.proj uses GitInfo against a .git
REM directory that doesn't exist (we extract from a tarball), so it fails
REM and never writes these files. build_init.cmd doesn't propagate the
REM failure (no `|| exit /b`), so the build continues -- but downstream
REM subdirs need these files to resolve MSBuild SDK references.
copy /Y "%RECIPE_DIR%\global.json" "%SRC_DIR%\global.json" || exit /b 1
copy /Y "%RECIPE_DIR%\Directory.Packages.props" "%SRC_DIR%\Directory.Packages.props" || exit /b 1
mkdir "%SRC_DIR%\build" 2>nul
copy /Y "%RECIPE_DIR%\wixver.props" "%SRC_DIR%\build\wixver.props" || exit /b 1

REM ============================================================================
REM Diagnostics -- keep until build is green; trim afterwards.
REM ============================================================================
where dotnet || exit /b 1
where nuget || exit /b 1
where msbuild
echo DOTNET_ROOT=%DOTNET_ROOT%
echo WixSkipVsDevCmd=%WixSkipVsDevCmd%
echo VCToolsInstallDir=%VCToolsInstallDir%
echo --- global.json ---
type "%SRC_DIR%\global.json"
echo --- Directory.Packages.props (head) ---
type "%SRC_DIR%\Directory.Packages.props" | findstr /N "^" | findstr "^[1-9]:" | findstr "^[1-5]:"
echo --- wixver.props ---
type "%SRC_DIR%\build\wixver.props"
echo ====================

REM ============================================================================
REM Run upstream build.
REM ============================================================================
call devbuild.cmd release || exit /b 1

REM Stage outputs.
mkdir "%LIBRARY_PREFIX%\wix" 2>nul
mkdir "%LIBRARY_PREFIX%\wix\sdk" 2>nul
mkdir "%LIBRARY_PREFIX%\wix\nupkgs" 2>nul

xcopy /E /I /Y "build\wix\Release\publish" "%LIBRARY_PREFIX%\wix\sdk" || exit /b 1

for %%f in (build\artifacts\WixToolset.*.wixext.*.nupkg) do (
  copy /Y "%%f" "%LIBRARY_PREFIX%\wix\nupkgs\" || exit /b 1
)

REM Tiny shim on PATH that calls into sdk\wix\wix.exe.
mkdir "%LIBRARY_BIN%" 2>nul
echo @"%%LIBRARY_PREFIX%%\wix\sdk\wix\wix.exe" %%* > "%LIBRARY_BIN%\wix.bat"

endlocal
