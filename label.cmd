@echo off
rem ============================================================================
rem  Double-click this file to start X-AnyLabeling labeling.
rem
rem  Why this .cmd exists (two invocation traps already hit once each):
rem    1. `.venv-label\Scripts\anylabeling.exe` starts with a dot, so PowerShell
rem       parses it as a module name and fails with
rem       "The module '.venv-label' could not be loaded".
rem    2. `.\scripts\label.ps1` only works when the current directory IS the repo
rem       root; from anywhere else it fails with "is not recognized".
rem  This file uses %~dp0 (its own directory = repo root), so it works from any
rem  working directory and when double-clicked.
rem
rem  NOTE: keep this file ASCII-only. cmd.exe reads .cmd/.bat in the system ANSI
rem  codepage, not UTF-8: non-ASCII bytes get mangled and even the `rem` prefix
rem  stops working, so the comment text is then executed as commands.
rem  (Chinese explanations live in scripts\label.ps1, which PowerShell reads as UTF-8.)
rem
rem  Usage:
rem    label.cmd                       open the default frames directory
rem    label.cmd -Images <dir>         open another directory
rem    label.cmd -DryRun               print the command without launching
rem ============================================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\label.ps1" %*
if errorlevel 1 (
  echo.
  echo Launch failed with error code %errorlevel%. See the output above.
  pause
)
