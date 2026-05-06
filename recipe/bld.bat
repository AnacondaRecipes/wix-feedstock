@echo on
setlocal

REM Put the build-helper nuget.exe on PATH for upstream devbuild.cmd.
REM (nuget.exe lives in %SRC_DIR%\build_helpers; never staged into %PREFIX%.)
set "PATH=%SRC_DIR%\build_helpers;%PATH%"

where dotnet || exit /b 1
where nuget || exit /b 1

REM PBP win-64 AMI ships VS2022 BuildTools without the .NET SDK component, so
REM VS's MSBuild can't locate Microsoft.NET.Sdk in its own install. Point
REM MSBuild at the conda-installed dotnet SDK's Sdks directory and drop a
REM global.json so the SDK resolver pins to the exact version we provide.
set "DOTNET_ROOT=%BUILD_PREFIX%\dotnet"
set "MSBuildSDKsPath=%BUILD_PREFIX%\dotnet\sdk\8.0.100\Sdks"
echo {"sdk": {"version": "8.0.100", "rollForward": "latestFeature"}} > global.json

REM Run upstream build. devbuild.cmd locates VS2022 via vswhere and shells
REM into a Developer Command Prompt before invoking msbuild.
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
