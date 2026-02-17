# Known bugs and problems with the GUI

- If Docker Desktop is not running on Windows and the user selects a local container, the script still provides the user with the interface but fails on starting a container. The Docker detection mechanism needs to be patched so that Docker Desktop on the Windows machine that is starting the script has time to start and is indeed starting correctly. This worked before and likely broke after the test refactoring.

- 