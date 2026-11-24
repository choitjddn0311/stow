# Stow for Windows (개발 중)

Stow의 Windows 버전입니다. C#·.NET 10 + WinUI 3로 만들고 있으며, 아직 배포하지 않았습니다.

| 폴더 | 내용 |
|---|---|
| `src/Stow.Core/` | 화면과 무관한 로직. Windows가 아닌 곳에서도 빌드·테스트할 수 있습니다 |
| `src/Stow.App/` | WinUI 3 앱(설치 패키지 없이 실행). Windows에서만 빌드됩니다 |
| `tests/Stow.Core.Tests/` | 공통 로직 테스트(xUnit v3) |

```powershell
dotnet test --project tests/Stow.Core.Tests
dotnet publish src/Stow.App/Stow.App.csproj -c Release -r win-x64 -p:Platform=x64 --self-contained -o out/win-x64
```

필요 환경: .NET SDK 10(`global.json`), Windows 10(22H2)·11. PR마다 GitHub Actions(Windows)가 x64·ARM64 실행 파일을 만들어 아티팩트로 올립니다.
