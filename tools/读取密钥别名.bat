@echo off
chcp 65001 >nul
setlocal

set P12=E:\zhixue-signing\zhixue-debug.p12

echo ================================================================
echo  读取密钥库别名（keytool -list）
echo ================================================================
echo.
echo  文件: %P12%
echo.
echo  接下来会提示 "输入密钥库口令" —— 输入你的 p12 密码，回车。
echo  （密码不会显示出来，这是正常的，直接输完回车即可）
echo.
echo ----------------------------------------------------------------

if not exist "%P12%" (
  echo [错误] 找不到文件: %P12%
  echo.
  pause
  exit /b 1
)

echo.
echo === 尝试 1/2: 用 JDK 8 的 keytool ===
set KT=D:\soft\jdk_1.8.0_241\bin\keytool.exe
if exist "%KT%" (
  "%KT%" -list -v -keystore "%P12%" -storetype PKCS12
) else (
  echo   未找到 %KT%，跳过
)

echo.
echo ----------------------------------------------------------------
echo === 尝试 2/2: 用 DevEco 自带 JBR 的 keytool ===
set KT2=D:\DevEco\DevEco Studio\jbr\bin\keytool.exe
if exist "%KT2%" (
  "%KT2%" -list -v -keystore "%P12%" -storetype PKCS12
) else (
  echo   未找到 %KT2%，跳过
  echo   尝试 PATH 里的 keytool...
  keytool -list -v -keystore "%P12%" -storetype PKCS12
)

echo.
echo ----------------------------------------------------------------
echo.
echo  请在上面的输出里找这一行:
echo.
echo      别名: xxxxx
echo.
echo  那个 xxxxx 就是「密钥别名」。
echo  「密钥密码」先填和密钥库密码相同的值。
echo.
pause
