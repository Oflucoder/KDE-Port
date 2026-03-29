# KDE-Port Build/Deploy Scripts

These scripts are conservative wrappers around CMake/Ninja and windeployqt.
They keep existing defaults from this workspace and let you override paths per run.

## 1) Build + Install one project

```powershell
pwsh -File C:/KDE-Port/scripts/kde-build.ps1 `
  -SourceDir C:/KDE-Port/src/dolphin `
  -BuildDir C:/KDE-Port/build/dolphin `
  -Config Debug `
  -Jobs 12
```

## 2) Deploy one executable

```powershell
pwsh -File C:/KDE-Port/scripts/kde-deploy.ps1 `
  -AppExe C:/KDE-Port/build/dolphin/bin/dolphin.exe `
  -Destination C:/KDE-Port/deploy/dolphin-debug `
  -Config Debug
```

## 3) Build and deploy in one command

```powershell
pwsh -File C:/KDE-Port/scripts/kde-build-deploy.ps1 `
  -SourceDir C:/KDE-Port/src/dolphin `
  -BuildDir C:/KDE-Port/build/dolphin `
  -AppExe C:/KDE-Port/build/dolphin/bin/dolphin.exe `
  -Destination C:/KDE-Port/deploy/dolphin-debug `
  -Config Debug `
  -Jobs 12
```

## 4) Deploy everything from install/bin

```powershell
pwsh -File C:/KDE-Port/scripts/deploy-all-install-bin.ps1 `
  -InstallBin C:/KDE-Port/install/bin `
  -DeployRoot C:/KDE-Port/deploy/install-bin `
  -Config Debug `
  -ContinueOnError
```

This mode automatically falls back for non-Qt executables when `windeployqt` reports "does not seem to be a Qt executable".

## 5) Deploy only KDE GUI apps

```powershell
pwsh -File C:/KDE-Port/scripts/deploy-kde-apps.ps1 `
  -InstallBin C:/KDE-Port/install/bin `
  -DeployRoot C:/KDE-Port/deploy/apps `
  -Config Debug `
  -ContinueOnError
```

Default app list:
- dolphin.exe
- kate.exe
- konsole.exe
- kwrite.exe
- kcmshell6.exe
- kded6.exe

## 6) Smoke test deployed outputs

```powershell
pwsh -File C:/KDE-Port/scripts/smoke-test-deploy.ps1 `
  -DeployRoot C:/KDE-Port/deploy/apps `
  -ContinueOnError
```

By default this is a non-launch dependency audit (no app windows, no popup dialogs).

To run the old launch-based smoke test explicitly:

```powershell
pwsh -File C:/KDE-Port/scripts/smoke-test-deploy.ps1 `
  -DeployRoot C:/KDE-Port/deploy/apps `
  -LaunchApps `
  -CollectEventLog `
  -ContinueOnError
```

Launch mode now sets app-local runtime environment and writes logs under each app folder:
- logs/<app>.<timestamp>.stdout.log
- logs/<app>.<timestamp>.stderr.log
- logs/<app>.<timestamp>.meta.txt
- logs/<app>.<timestamp>.eventlog.txt (when `-CollectEventLog` is used)

To quickly inspect non-empty stderr logs:

```powershell
pwsh -File C:/KDE-Port/scripts/read-launch-logs.ps1 -DeployRoot C:/KDE-Port/deploy/apps
```

## 7) Run directly from install/bin with runtime env

If you see missing DLL popups when launching from `install/bin`, run apps with this helper:

```powershell
pwsh -File C:/KDE-Port/scripts/run-installed-app.ps1 -AppName dolphin
pwsh -File C:/KDE-Port/scripts/run-installed-app.ps1 -AppName kate
```

This script sets `PATH`, `QT_PLUGIN_PATH`, and `QML2_IMPORT_PATH` to your KDE/Qt install layout before launch.

## Notes

- `kde-build.ps1` runs configure, build, and install.
- `kde-deploy.ps1` copies app + Qt runtime (windeployqt) + KDE runtime/plugin trees.
- All key paths can be overridden with parameters (`-InstallPrefix`, `-ToolchainFile`, `-QtRoot`).
- `-Clean` removes the selected build directory before configure.
- Deployment now includes compiler runtime by default (unless `-NoCompilerRuntime` is passed).
- Each deployed app folder contains `run_<app>.bat`, which sets `PATH`, `QT_PLUGIN_PATH`, and `QML2_IMPORT_PATH` before launch.
- Each deployed app folder also contains `qt.conf` with local plugin/QML paths.
