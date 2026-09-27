@echo off
REM Launch the packaged client against the local backend with ordinary Keycloak sign-in.
"%~dp0dist\AstralDeep.exe" --deployment-profile "%~dp0deployment\local-backend-profile.json" %*
