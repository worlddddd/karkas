# KarkasLot Windows kurulum paketi

Bu repository, Windows üzerinde tek PowerShell dosyasıyla çalışır bir başlangıç uygulaması oluşturur.

## Gereksinimler

- Windows 10/11
- PowerShell 5.1 veya PowerShell 7
- .NET 8 SDK
- Node.js 18+
- Docker Desktop

## Kurulum

PowerShell'i yönetici olarak açmanız gerekmez. Repository klasöründe çalıştırın:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\create-karkaslot.ps1
```

Script şunları yapar:

- `karkaslot` uygulama klasörünü oluşturur
- PostgreSQL Docker konteynerini başlatır
- ASP.NET Core API oluşturur
- React/Vite arayüzünü oluşturur
- Bağımlılıkları kurar
- `karkaslot.zip` dosyasını üretir

## Çalıştırma

API:

```powershell
cd .\karkaslot\backend\KarkasLot.Api
dotnet run --urls http://localhost:5159
```

Yeni terminalde frontend:

```powershell
cd .\karkaslot\frontend\karkaslot-web
npm run dev
```

Adresler:

- Web: http://localhost:5173
- API health: http://localhost:5159/api/health
- PostgreSQL: localhost:5432

## Durdurma

```powershell
cd .\karkaslot
docker compose down
```

Veritabanı verileriyle birlikte silmek için:

```powershell
docker compose down -v
```
