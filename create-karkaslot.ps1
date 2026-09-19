$ErrorActionPreference = "Stop"

$Root = Join-Path (Get-Location) "karkaslot"
$Api = Join-Path $Root "backend\KarkasLot.Api"
$Web = Join-Path $Root "frontend\karkaslot-web"

function Require-Command([string]$Name) {
  if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
    throw "$Name bulunamadı. Gerekli programı kurup tekrar deneyin."
  }
}

function Write-File([string]$Path, [string]$Content) {
  $parent = Split-Path $Path -Parent
  New-Item -ItemType Directory -Force -Path $parent | Out-Null
  Set-Content -Path $Path -Value $Content -Encoding UTF8
}

Require-Command dotnet
Require-Command node
Require-Command npm
Require-Command docker

if (Test-Path $Root) {
  Remove-Item $Root -Recurse -Force
}

New-Item -ItemType Directory -Force -Path $Root | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Root "db") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Root "backend") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Root "frontend") | Out-Null

Write-File (Join-Path $Root "docker-compose.yml") @'
services:
  postgres:
    image: postgres:16
    container_name: karkaslot-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: karkaslotdb
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
    ports:
      - "5432:5432"
    volumes:
      - karkaslot_pgdata:/var/lib/postgresql/data

volumes:
  karkaslot_pgdata:
'@

Write-File (Join-Path $Root "README.md") @'
# KarkasLot Windows kurulum paketi

Bu repository, Windows üzerinde tek PowerShell betiğiyle oluşturulan bir karkas işleme ve stok yönetimi uygulaması üretir.

## İçerik

- ASP.NET Core Web API
- PostgreSQL
- React + Vite frontend
- JWT tabanlı login/register
- Rol bazlı erişim (Admin, Manager, Warehouse, Production, Quality, Accounting)
- Lot / stok / sevk / fatura başlangıç akışı
- HACCP ve kalite takibi
- Corrective action / quality issue takibi
- Docker ile veritabanı yönetimi

## Gereksinimler

- Windows 10/11
- PowerShell 5.1 veya PowerShell 7
- .NET 8 SDK
- Node.js 18+
- Docker Desktop

## Kurulum

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\create-karkaslot.ps1
```

Script şunları yapar:

- `karkaslot` klasörünü oluşturur
- PostgreSQL Docker konteynerini hazırlar
- ASP.NET Core API ve React frontend oluşturur
- JWT auth, rol ve kalite/HACCP yapısını ekler
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
- API: http://localhost:5159
- Swagger: http://localhost:5159/swagger
- PostgreSQL: localhost:5432

## İlk hesap oluşturma

```powershell
Invoke-RestMethod -Method Post -Uri "http://localhost:5159/api/auth/register" -ContentType "application/json" -Body '{"username":"admin","password":"123456","fullName":"Admin Kullanıcı","email":"admin@test.com"}'
```

## Giriş

```powershell
Invoke-RestMethod -Method Post -Uri "http://localhost:5159/api/auth/login" -ContentType "application/json" -Body '{"username":"admin","password":"123456"}'
```

## Durdurma

```powershell
cd .\karkaslot
docker compose down
```

Veritabanı verileriyle birlikte silmek için:

```powershell
docker compose down -v
```
'@

Push-Location (Join-Path $Root "backend")
dotnet new webapi -n KarkasLot.Api --framework net8.0 --no-https --force | Out-Host
Pop-Location

Push-Location $Api
dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL --version 8.0.8 | Out-Host
dotnet add package Microsoft.EntityFrameworkCore.Design --version 8.0.8 | Out-Host
dotnet add package Microsoft.AspNetCore.Authentication.JwtBearer --version 8.0.8 | Out-Host
dotnet add package System.IdentityModel.Tokens.Jwt --version 8.0.1 | Out-Host
Pop-Location

Write-File (Join-Path $Api "appsettings.json") @'
{
  "ConnectionStrings": {
    "DefaultConnection": "Host=localhost;Port=5432;Database=karkaslotdb;Username=postgres;Password=postgres"
  },
  "Jwt": {
    "Key": "karkaslot-super-secret-key-1234567890",
    "Issuer": "karkaslot.api",
    "Audience": "karkaslot.client",
    "ExpiryMinutes": 480
  },
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "AllowedHosts": "*"
}
'@

Write-File (Join-Path $Api "Program.cs") @'
using System.Text;
using KarkasLot.Api.Data;
using KarkasLot.Api.Models;
using KarkasLot.Api.Services;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.EntityFrameworkCore;
using Microsoft.IdentityModel.Tokens;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddControllers();
builder.Services.AddEndpointsApiExplorer();
builder.Services.AddSwaggerGen();

var connectionString = builder.Configuration.GetConnectionString("DefaultConnection");
builder.Services.AddDbContext<AppDbContext>(options => options.UseNpgsql(connectionString));

builder.Services.AddCors(options =>
{
    options.AddPolicy("web", policy =>
    {
        policy.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod();
    });
});

builder.Services.AddScoped<JwtTokenService>();

builder.Services.AddAuthentication(options =>
{
    options.DefaultAuthenticateScheme = JwtBearerDefaults.AuthenticationScheme;
    options.DefaultChallengeScheme = JwtBearerDefaults.AuthenticationScheme;
})
.AddJwtBearer(options =>
{
    options.TokenValidationParameters = new TokenValidationParameters
    {
        ValidateIssuer = true,
        ValidateAudience = true,
        ValidateLifetime = true,
        ValidateIssuerSigningKey = true,
        ValidIssuer = builder.Configuration["Jwt:Issuer"],
        ValidAudience = builder.Configuration["Jwt:Audience"],
        IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(builder.Configuration["Jwt:Key"]!))
    };
});

builder.Services.AddAuthorization();

var app = builder.Build();

using (var scope = app.Services.CreateScope())
{
    var db = scope.ServiceProvider.GetRequiredService<AppDbContext>();
    db.Database.EnsureCreated();

    if (!db.Roles.Any())
    {
        db.Roles.AddRange(
            new Role { Name = "Admin" },
            new Role { Name = "Manager" },
            new Role { Name = "Warehouse" },
            new Role { Name = "Production" },
            new Role { Name = "Quality" },
            new Role { Name = "Accounting" }
        );
        db.SaveChanges();
    }

    if (!db.Products.Any())
    {
        db.Products.AddRange(
            new Product { Name = "Karkas Et", Unit = "kg" },
            new Product { Name = "Kuşbaşı", Unit = "kg" },
            new Product { Name = "Kıyma", Unit = "kg" }
        );
        db.Suppliers.Add(new Supplier { Name = "Varsayılan Tedarikçi" });
        db.SaveChanges();
    }
}

if (app.Environment.IsDevelopment())
{
    app.UseSwagger();
    app.UseSwaggerUI();
}

app.UseCors("web");
app.UseAuthentication();
app.UseAuthorization();
app.MapControllers();

app.Run();
'@

New-Item -ItemType Directory -Force -Path (Join-Path $Api "Data") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Api "Models") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Api "Controllers") | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Api "Services") | Out-Null

Write-File (Join-Path $Api "Models\Product.cs") @'
namespace KarkasLot.Api.Models;

public class Product
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public string Unit { get; set; } = "kg";
}
'@
Write-File (Join-Path $Api "Models\Supplier.cs") @'
namespace KarkasLot.Api.Models;

public class Supplier
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
}
'@
Write-File (Join-Path $Api "Models\Lot.cs") @'
namespace KarkasLot.Api.Models;

public class Lot
{
    public int Id { get; set; }
    public string LotNo { get; set; } = string.Empty;
    public int ProductId { get; set; }
    public int? SupplierId { get; set; }
    public decimal Amount { get; set; }
    public DateTime ReceivedAt { get; set; } = DateTime.UtcNow;
    public string Unit { get; set; } = "kg";
    public string Status { get; set; } = "Kullanılabilir";
    public DateTime? ExpiryDate { get; set; }
    public string? SourceRef { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public Product? Product { get; set; }
    public Supplier? Supplier { get; set; }
}
'@
Write-File (Join-Path $Api "Models\StockMovement.cs") @'
namespace KarkasLot.Api.Models;

public class StockMovement
{
    public int Id { get; set; }
    public int LotId { get; set; }
    public string MovementType { get; set; } = "IN";
    public decimal Qty { get; set; }
    public string? RelatedRef { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public Lot? Lot { get; set; }
}
'@
Write-File (Join-Path $Api "Models\Shipment.cs") @'
namespace KarkasLot.Api.Models;

public class Shipment
{
    public int Id { get; set; }
    public string ShipmentNo { get; set; } = string.Empty;
    public string CustomerName { get; set; } = string.Empty;
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public ICollection<ShipmentItem>? Items { get; set; }
}
'@
Write-File (Join-Path $Api "Models\ShipmentItem.cs") @'
namespace KarkasLot.Api.Models;

public class ShipmentItem
{
    public int Id { get; set; }
    public int ShipmentId { get; set; }
    public int LotId { get; set; }
    public decimal Qty { get; set; }
    public Shipment? Shipment { get; set; }
    public Lot? Lot { get; set; }
}
'@
Write-File (Join-Path $Api "Models\Customer.cs") @'
namespace KarkasLot.Api.Models;

public class Customer
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public string TaxNumber { get; set; } = string.Empty;
    public string Address { get; set; } = string.Empty;
}
'@
Write-File (Join-Path $Api "Models\Invoice.cs") @'
namespace KarkasLot.Api.Models;

public class Invoice
{
    public int Id { get; set; }
    public string InvoiceNo { get; set; } = string.Empty;
    public int? ShipmentId { get; set; }
    public int? CustomerId { get; set; }
    public decimal TotalAmount { get; set; }
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}
'@
Write-File (Join-Path $Api "Models\HaccpCheck.cs") @'
namespace KarkasLot.Api.Models;

public class HaccpCheck
{
    public int Id { get; set; }
    public int LotId { get; set; }
    public string CheckType { get; set; } = string.Empty;
    public decimal? Value { get; set; }
    public decimal? LimitMin { get; set; }
    public decimal? LimitMax { get; set; }
    public string Result { get; set; } = string.Empty;
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}
'@
Write-File (Join-Path $Api "Models\QualityIssue.cs") @'
namespace KarkasLot.Api.Models;

public class QualityIssue
{
    public int Id { get; set; }
    public int? LotId { get; set; }
    public string IssueType { get; set; } = string.Empty;
    public string Description { get; set; } = string.Empty;
    public string Status { get; set; } = "Açık";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}
'@
Write-File (Join-Path $Api "Models\CorrectiveAction.cs") @'
namespace KarkasLot.Api.Models;

public class CorrectiveAction
{
    public int Id { get; set; }
    public int QualityIssueId { get; set; }
    public string ActionText { get; set; } = string.Empty;
    public string? ResponsibleUser { get; set; }
    public DateTime? DueDate { get; set; }
    public string Status { get; set; } = "Açık";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
}
'@
Write-File (Join-Path $Api "Models\Role.cs") @'
namespace KarkasLot.Api.Models;

public class Role
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
}
'@
Write-File (Join-Path $Api "Models\User.cs") @'
namespace KarkasLot.Api.Models;

public class User
{
    public int Id { get; set; }
    public string Username { get; set; } = string.Empty;
    public string PasswordHash { get; set; } = string.Empty;
    public string? FullName { get; set; }
    public string? Email { get; set; }
    public bool IsActive { get; set; } = true;
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public ICollection<UserRole> UserRoles { get; set; } = new List<UserRole>();
}
'@
Write-File (Join-Path $Api "Models\UserRole.cs") @'
namespace KarkasLot.Api.Models;

public class UserRole
{
    public int UserId { get; set; }
    public int RoleId { get; set; }
    public User? User { get; set; }
    public Role? Role { get; set; }
}
'@

Write-File (Join-Path $Api "Data\AppDbContext.cs") @'
using KarkasLot.Api.Models;
using Microsoft.EntityFrameworkCore;

namespace KarkasLot.Api.Data;

public class AppDbContext : DbContext
{
    public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) { }

    public DbSet<Product> Products => Set<Product>();
    public DbSet<Supplier> Suppliers => Set<Supplier>();
    public DbSet<Lot> Lots => Set<Lot>();
    public DbSet<StockMovement> StockMovements => Set<StockMovement>();
    public DbSet<Shipment> Shipments => Set<Shipment>();
    public DbSet<ShipmentItem> ShipmentItems => Set<ShipmentItem>();
    public DbSet<Customer> Customers => Set<Customer>();
    public DbSet<Invoice> Invoices => Set<Invoice>();
    public DbSet<HaccpCheck> HaccpChecks => Set<HaccpCheck>();
    public DbSet<QualityIssue> QualityIssues => Set<QualityIssue>();
    public DbSet<CorrectiveAction> CorrectiveActions => Set<CorrectiveAction>();
    public DbSet<User> Users => Set<User>();
    public DbSet<Role> Roles => Set<Role>();
    public DbSet<UserRole> UserRoles => Set<UserRole>();

    protected override void OnModelCreating(ModelBuilder modelBuilder)
    {
        modelBuilder.Entity<User>().ToTable("users");
        modelBuilder.Entity<Role>().ToTable("roles");
        modelBuilder.Entity<UserRole>().ToTable("user_roles");
        modelBuilder.Entity<UserRole>().HasKey(x => new { x.UserId, x.RoleId });
        modelBuilder.Entity<UserRole>().HasOne(x => x.User).WithMany(x => x.UserRoles).HasForeignKey(x => x.UserId);
        modelBuilder.Entity<UserRole>().HasOne(x => x.Role).WithMany().HasForeignKey(x => x.RoleId);

        modelBuilder.Entity<Product>().ToTable("products");
        modelBuilder.Entity<Supplier>().ToTable("suppliers");
        modelBuilder.Entity<Lot>().ToTable("lots");
        modelBuilder.Entity<StockMovement>().ToTable("stock_movements");
        modelBuilder.Entity<Shipment>().ToTable("shipments");
        modelBuilder.Entity<ShipmentItem>().ToTable("shipment_items");
        modelBuilder.Entity<Customer>().ToTable("customers");
        modelBuilder.Entity<Invoice>().ToTable("invoices");
        modelBuilder.Entity<HaccpCheck>().ToTable("haccp_checks");
        modelBuilder.Entity<QualityIssue>().ToTable("quality_issues");
        modelBuilder.Entity<CorrectiveAction>().ToTable("corrective_actions");

        modelBuilder.Entity<Lot>().HasOne(x => x.Product).WithMany().HasForeignKey(x => x.ProductId);
        modelBuilder.Entity<Lot>().HasOne(x => x.Supplier).WithMany().HasForeignKey(x => x.SupplierId);
        modelBuilder.Entity<StockMovement>().HasOne(x => x.Lot).WithMany().HasForeignKey(x => x.LotId);
        modelBuilder.Entity<ShipmentItem>().HasOne(x => x.Shipment).WithMany(x => x.Items).HasForeignKey(x => x.ShipmentId);
        modelBuilder.Entity<ShipmentItem>().HasOne(x => x.Lot).WithMany().HasForeignKey(x => x.LotId);

        base.OnModelCreating(modelBuilder);
    }
}
'@

Write-File (Join-Path $Api "Services\JwtTokenService.cs") @'
using System.IdentityModel.Tokens.Jwt;
using System.Security.Claims;
using System.Text;
using KarkasLot.Api.Models;
using Microsoft.IdentityModel.Tokens;

namespace KarkasLot.Api.Services;

public class JwtTokenService
{
    private readonly IConfiguration _configuration;

    public JwtTokenService(IConfiguration configuration)
    {
        _configuration = configuration;
    }

    public string GenerateToken(User user, IEnumerable<string> roles)
    {
        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(_configuration["Jwt:Key"]!));
        var creds = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);

        var claims = new List<Claim>
        {
            new(ClaimTypes.NameIdentifier, user.Id.ToString()),
            new(ClaimTypes.Name, user.Username),
            new(ClaimTypes.Email, user.Email ?? string.Empty)
        };

        foreach (var role in roles)
            claims.Add(new Claim(ClaimTypes.Role, role));

        var token = new JwtSecurityToken(
            issuer: _configuration["Jwt:Issuer"],
            audience: _configuration["Jwt:Audience"],
            claims: claims,
            expires: DateTime.UtcNow.AddMinutes(double.Parse(_configuration["Jwt:ExpiryMinutes"]!)),
            signingCredentials: creds);

        return new JwtSecurityTokenHandler().WriteToken(token);
    }
}
'@

Write-File (Join-Path $Api "Controllers\AuthController.cs") @'
using System.Security.Cryptography;
using System.Text;
using KarkasLot.Api.Data;
using KarkasLot.Api.Models;
using KarkasLot.Api.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace KarkasLot.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
public class AuthController : ControllerBase
{
    private readonly AppDbContext _context;
    private readonly JwtTokenService _jwtTokenService;

    public AuthController(AppDbContext context, JwtTokenService jwtTokenService)
    {
        _context = context;
        _jwtTokenService = jwtTokenService;
    }

    [HttpPost("register")]
    public async Task<ActionResult> Register(RegisterRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.Username) || string.IsNullOrWhiteSpace(request.Password))
            return BadRequest("Kullanıcı adı ve şifre gerekli.");

        if (await _context.Users.AnyAsync(x => x.Username == request.Username))
            return BadRequest("Bu kullanıcı adı mevcut.");

        var user = new User
        {
            Username = request.Username,
            PasswordHash = HashPassword(request.Password),
            FullName = request.FullName,
            Email = request.Email
        };

        _context.Users.Add(user);
        await _context.SaveChangesAsync();

        var defaultRole = await _context.Roles.FirstOrDefaultAsync(x => x.Name == "Manager");
        if (defaultRole != null)
        {
            _context.UserRoles.Add(new UserRole { UserId = user.Id, RoleId = defaultRole.Id });
            await _context.SaveChangesAsync();
        }

        return Ok(new { user.Id, user.Username, user.FullName });
    }

    [HttpPost("login")]
    public async Task<ActionResult> Login(LoginRequest request)
    {
        var user = await _context.Users.Include(x => x.UserRoles).ThenInclude(x => x.Role).FirstOrDefaultAsync(x => x.Username == request.Username && x.IsActive);
        if (user == null) return Unauthorized("Kullanıcı bulunamadı.");
        if (!VerifyPassword(request.Password, user.PasswordHash)) return Unauthorized("Şifre yanlış.");

        var roles = user.UserRoles.Where(x => x.Role != null).Select(x => x.Role!.Name).ToList();

        return Ok(new { token = _jwtTokenService.GenerateToken(user, roles), user = new { user.Id, user.Username, user.FullName, user.Email, roles } });
    }

    [HttpGet("me")]
    [Authorize]
    public async Task<ActionResult> Me()
    {
        var userId = int.Parse(User.FindFirst(System.Security.Claims.ClaimTypes.NameIdentifier)!.Value);
        var user = await _context.Users.Include(x => x.UserRoles).ThenInclude(x => x.Role).FirstOrDefaultAsync(x => x.Id == userId);
        if (user == null) return Unauthorized();
        var roles = user.UserRoles.Where(x => x.Role != null).Select(x => x.Role!.Name).ToList();
        return Ok(new { user.Id, user.Username, user.FullName, user.Email, roles });
    }

    private static string HashPassword(string password)
    {
        using var sha256 = SHA256.Create();
        var bytes = Encoding.UTF8.GetBytes(password + "KARKASLOT_SALT");
        return Convert.ToHexString(sha256.ComputeHash(bytes));
    }

    private static bool VerifyPassword(string password, string hash)
    {
        return HashPassword(password) == hash;
    }
}

public record RegisterRequest(string Username, string Password, string? FullName, string? Email);
public record LoginRequest(string Username, string Password);
'@
Write-File (Join-Path $Api "Controllers\RolesController.cs") @'
using KarkasLot.Api.Data;
using KarkasLot.Api.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace KarkasLot.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
[Authorize(Roles = "Admin,Manager")]
public class RolesController : ControllerBase
{
    private readonly AppDbContext _context;
    public RolesController(AppDbContext context) => _context = context;

    [HttpGet]
    public async Task<ActionResult<IEnumerable<Role>>> Get() => await _context.Roles.OrderBy(x => x.Name).ToListAsync();
}
'@
Write-File (Join-Path $Api "Controllers\UsersController.cs") @'
using KarkasLot.Api.Data;
using KarkasLot.Api.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace KarkasLot.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
[Authorize(Roles = "Admin,Manager")]
public class UsersController : ControllerBase
{
    private readonly AppDbContext _context;
    public UsersController(AppDbContext context) => _context = context;

    [HttpGet]
    public async Task<ActionResult<IEnumerable<object>>> Get() => Ok(await _context.Users.Include(x => x.UserRoles).ThenInclude(x => x.Role).Select(x => new { x.Id, x.Username, x.FullName, x.Email, x.IsActive, Roles = x.UserRoles.Select(ur => ur.Role!.Name).ToList() }).OrderBy(x => x.Username).ToListAsync());

    [HttpPost("assign-role")]
    public async Task<ActionResult> AssignRole(AssignRoleRequest request)
    {
        var user = await _context.Users.FindAsync(request.UserId);
        if (user == null) return NotFound("Kullanıcı bulunamadı.");
        var role = await _context.Roles.FirstOrDefaultAsync(x => x.Name == request.RoleName);
        if (role == null) return NotFound("Rol bulunamadı.");
        var exists = await _context.UserRoles.AnyAsync(x => x.UserId == request.UserId && x.RoleId == role.Id);
        if (!exists)
        {
            _context.UserRoles.Add(new UserRole { UserId = request.UserId, RoleId = role.Id });
            await _context.SaveChangesAsync();
        }
        return Ok(new { message = "Rol atandı." });
    }
}

public record AssignRoleRequest(int UserId, string RoleName);
'@
Write-File (Join-Path $Api "Controllers\ProductsController.cs") @'
using KarkasLot.Api.Data;
using KarkasLot.Api.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace KarkasLot.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
[Authorize]
public class ProductsController : ControllerBase
{
    private readonly AppDbContext _context;
    public ProductsController(AppDbContext context) => _context = context;

    [HttpGet]
    public async Task<ActionResult<IEnumerable<Product>>> Get() => await _context.Products.OrderBy(x => x.Name).ToListAsync();

    [HttpPost]
    public async Task<ActionResult> Post(Product product)
    {
        if (string.IsNullOrWhiteSpace(product.Name)) return BadRequest("Ürün adı gerekli.");
        _context.Products.Add(product);
        await _context.SaveChangesAsync();
        return Ok(product);
    }
}
'@
Write-File (Join-Path $Api "Controllers\SuppliersController.cs") @'
using KarkasLot.Api.Data;
using KarkasLot.Api.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace KarkasLot.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
[Authorize]
public class SuppliersController : ControllerBase
{
    private readonly AppDbContext _context;
    public SuppliersController(AppDbContext context) => _context = context;

    [HttpGet]
    public async Task<ActionResult<IEnumerable<Supplier>>> Get() => await _context.Suppliers.OrderBy(x => x.Name).ToListAsync();

    [HttpPost]
    public async Task<ActionResult> Post(Supplier supplier)
    {
        if (string.IsNullOrWhiteSpace(supplier.Name)) return BadRequest("Tedarikçi adı gerekli.");
        _context.Suppliers.Add(supplier);
        await _context.SaveChangesAsync();
        return Ok(supplier);
    }
}
'@
Write-File (Join-Path $Api "Controllers\LotsController.cs") @'
using KarkasLot.Api.Data;
using KarkasLot.Api.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace KarkasLot.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
[Authorize]
public class LotsController : ControllerBase
{
    private readonly AppDbContext _context;
    public LotsController(AppDbContext context) => _context = context;

    [HttpGet]
    public async Task<ActionResult<IEnumerable<object>>> Get() => Ok(await _context.Lots.Include(x => x.Product).Include(x => x.Supplier).OrderByDescending(x => x.CreatedAt).Select(x => new { x.Id, x.LotNo, ProductName = x.Product != null ? x.Product.Name : "", SupplierName = x.Supplier != null ? x.Supplier.Name : "", x.Amount, x.Unit, x.Status, x.ExpiryDate, x.ReceivedAt, AvailableQty = _context.StockMovements.Where(m => m.LotId == x.Id).Sum(m => m.MovementType == "IN" ? m.Qty : -m.Qty) }).ToListAsync());

    [HttpPost("receipt")]
    public async Task<ActionResult> Receipt([FromBody] ReceiptRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.LotNo)) return BadRequest("Lot numarası gerekli.");
        if (request.Amount <= 0) return BadRequest("Miktar sıfırdan büyük olmalı.");
        if (!await _context.Products.AnyAsync(x => x.Id == request.ProductId)) return BadRequest("Ürün bulunamadı.");
        var lot = new Lot { LotNo = request.LotNo.Trim(), ProductId = request.ProductId, SupplierId = request.SupplierId, Amount = request.Amount, Unit = request.Unit ?? "kg", ExpiryDate = request.ExpiryDate, SourceRef = request.SourceRef, Status = "Kullanılabilir" };
        _context.Lots.Add(lot);
        await _context.SaveChangesAsync();
        _context.StockMovements.Add(new StockMovement { LotId = lot.Id, MovementType = "IN", Qty = lot.Amount, RelatedRef = request.SourceRef ?? "receipt" });
        await _context.SaveChangesAsync();
        return Ok(new { lot.Id, lot.LotNo, lot.Amount });
    }
}

public record ReceiptRequest(string LotNo, int ProductId, int? SupplierId, decimal Amount, string? Unit, DateTime? ExpiryDate, string? SourceRef);
'@
Write-File (Join-Path $Api "Controllers\ShipmentsController.cs") @'
using KarkasLot.Api.Data;
using KarkasLot.Api.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace KarkasLot.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
[Authorize]
public class ShipmentsController : ControllerBase
{
    private readonly AppDbContext _context;
    public ShipmentsController(AppDbContext context) => _context = context;

    [HttpGet]
    public async Task<ActionResult<IEnumerable<object>>> Get() => Ok(await _context.Shipments.Include(x => x.Items).ThenInclude(x => x.Lot).OrderByDescending(x => x.CreatedAt).Select(x => new { x.Id, x.ShipmentNo, x.CustomerName, x.CreatedAt, LotSummary = string.Join(" | ", x.Items.Select(i => i.Lot!.LotNo + ": " + i.Qty + " kg")) }).ToListAsync());

    [HttpPost]
    public async Task<ActionResult> Post([FromBody] ShipmentRequest request)
    {
        if (string.IsNullOrWhiteSpace(request.ShipmentNo) || string.IsNullOrWhiteSpace(request.CustomerName)) return BadRequest("Sevk numarası ve müşteri adı gereklidir.");
        if (request.Items.Count == 0) return BadRequest("En az bir lot eklenmelidir.");
        var shipment = new Shipment { ShipmentNo = request.ShipmentNo, CustomerName = request.CustomerName };
        _context.Shipments.Add(shipment);
        await _context.SaveChangesAsync();
        foreach (var item in request.Items)
        {
            var lot = await _context.Lots.FirstOrDefaultAsync(x => x.Id == item.LotId);
            if (lot == null) return BadRequest($"Lot bulunamadı: {item.LotId}");
            var available = await _context.StockMovements.Where(x => x.LotId == item.LotId).SumAsync(x => x.MovementType == "IN" ? x.Qty : -x.Qty);
            if (item.Qty <= 0 || available < item.Qty) return BadRequest($"{lot.LotNo} için yetersiz stok.");
            _context.ShipmentItems.Add(new ShipmentItem { ShipmentId = shipment.Id, LotId = item.LotId, Qty = item.Qty });
            _context.StockMovements.Add(new StockMovement { LotId = item.LotId, MovementType = "OUT", Qty = item.Qty, RelatedRef = "shipment:" + shipment.ShipmentNo });
        }
        await _context.SaveChangesAsync();
        return Ok(new { shipment.Id, shipment.ShipmentNo, shipment.CustomerName });
    }
}

public record ShipmentRequest(string ShipmentNo, string CustomerName, List<ShipmentItemRequest> Items);
public record ShipmentItemRequest(int LotId, decimal Qty);
'@
Write-File (Join-Path $Api "Controllers\HealthController.cs") @'
using Microsoft.AspNetCore.Mvc;

namespace KarkasLot.Api.Controllers;

[ApiController]
[Route("api")]
public class HealthController : ControllerBase
{
    [HttpGet("health")]
    public IActionResult Health() => Ok(new { status = "ok" });
}
'@
Write-File (Join-Path $Api "Controllers\CustomersController.cs") @'
using KarkasLot.Api.Data;
using KarkasLot.Api.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace KarkasLot.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
[Authorize]
public class CustomersController : ControllerBase
{
    private readonly AppDbContext _context;
    public CustomersController(AppDbContext context) => _context = context;

    [HttpGet]
    public async Task<ActionResult<IEnumerable<Customer>>> Get() => await _context.Customers.OrderBy(x => x.Name).ToListAsync();

    [HttpPost]
    public async Task<ActionResult> Post(Customer customer)
    {
        if (string.IsNullOrWhiteSpace(customer.Name)) return BadRequest("Müşteri adı gerekli.");
        _context.Customers.Add(customer);
        await _context.SaveChangesAsync();
        return Ok(customer);
    }
}
'@
Write-File (Join-Path $Api "Controllers\HaccpController.cs") @'
using KarkasLot.Api.Data;
using KarkasLot.Api.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace KarkasLot.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
[Authorize]
public class HaccpController : ControllerBase
{
    private readonly AppDbContext _context;
    public HaccpController(AppDbContext context) => _context = context;

    [HttpGet]
    public async Task<ActionResult<IEnumerable<HaccpCheck>>> Get() => await _context.HaccpChecks.OrderByDescending(x => x.CreatedAt).ToListAsync();

    [HttpPost]
    public async Task<ActionResult> Post(HaccpCheck check)
    {
        if (check.LotId <= 0 || string.IsNullOrWhiteSpace(check.CheckType)) return BadRequest("Lot ve kontrol tipi gerekli.");
        _context.HaccpChecks.Add(check);
        await _context.SaveChangesAsync();
        return Ok(check);
    }
}
'@
Write-File (Join-Path $Api "Controllers\QualityController.cs") @'
using KarkasLot.Api.Data;
using KarkasLot.Api.Models;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

namespace KarkasLot.Api.Controllers;

[ApiController]
[Route("api/[controller]")]
[Authorize]
public class QualityController : ControllerBase
{
    private readonly AppDbContext _context;
    public QualityController(AppDbContext context) => _context = context;

    [HttpGet("issues")]
    public async Task<ActionResult<IEnumerable<QualityIssue>>> GetIssues() => await _context.QualityIssues.OrderByDescending(x => x.CreatedAt).ToListAsync();

    [HttpPost("issues")]
    public async Task<ActionResult> PostIssue(QualityIssue issue)
    {
        _context.QualityIssues.Add(issue);
        await _context.SaveChangesAsync();
        return Ok(issue);
    }

    [HttpGet("actions")]
    public async Task<ActionResult<IEnumerable<CorrectiveAction>>> GetActions() => await _context.CorrectiveActions.OrderByDescending(x => x.CreatedAt).ToListAsync();

    [HttpPost("actions")]
    public async Task<ActionResult> PostAction(CorrectiveAction action)
    {
        _context.CorrectiveActions.Add(action);
        await _context.SaveChangesAsync();
        return Ok(action);
    }
}
'@

Push-Location (Join-Path $Root "frontend")
npm create vite@latest karkaslot-web -- --template react | Out-Host
Pop-Location

Write-File (Join-Path $Web "src\services\api.js") @'
const API = "http://localhost:5159/api";

async function request(url, options = {}) {
  const response = await fetch(API + url, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options
  });

  const text = await response.text();
  const data = text ? JSON.parse(text) : null;

  if (!response.ok) {
    throw new Error(typeof data === "string" ? data : "İşlem başarısız.");
  }

  return data;
}

export const login = (username, password) => request("/auth/login", { method: "POST", body: JSON.stringify({ username, password }) });
export const getProducts = () => request("/products", { headers: { Authorization: `Bearer ${localStorage.getItem("token")}` } });
export const getSuppliers = () => request("/suppliers", { headers: { Authorization: `Bearer ${localStorage.getItem("token")}` } });
export const getLots = () => request("/lots", { headers: { Authorization: `Bearer ${localStorage.getItem("token")}` } });
export const getShipments = () => request("/shipments", { headers: { Authorization: `Bearer ${localStorage.getItem("token")}` } });
export const getCustomers = () => request("/customers", { headers: { Authorization: `Bearer ${localStorage.getItem("token")}` } });
export const getUsers = () => request("/users", { headers: { Authorization: `Bearer ${localStorage.getItem("token")}` } });
export const getRoles = () => request("/roles", { headers: { Authorization: `Bearer ${localStorage.getItem("token")}` } });
export const getHaccp = () => request("/haccp", { headers: { Authorization: `Bearer ${localStorage.getItem("token")}` } });
export const getQualityIssues = () => request("/quality/issues", { headers: { Authorization: `Bearer ${localStorage.getItem("token")}` } });
export const getQualityActions = () => request("/quality/actions", { headers: { Authorization: `Bearer ${localStorage.getItem("token")}` } });
export const assignUserRole = (userId, roleName) => request("/users/assign-role", { method: "POST", headers: { Authorization: `Bearer ${localStorage.getItem("token")}` }, body: JSON.stringify({ userId, roleName }) });
export const createReceipt = (body) => request("/lots/receipt", { method: "POST", headers: { Authorization: `Bearer ${localStorage.getItem("token")}` }, body: JSON.stringify(body) });
export const createShipment = (body) => request("/shipments", { method: "POST", headers: { Authorization: `Bearer ${localStorage.getItem("token")}` }, body: JSON.stringify(body) });
'@

Write-File (Join-Path $Web "src\App.jsx") @'
import { useEffect, useMemo, useState } from "react";
import { login, getProducts, getSuppliers, getLots, getShipments, getUsers, getRoles, getHaccp, getQualityIssues, getQualityActions, assignUserRole, createReceipt, createShipment } from "./services/api";
import "./index.css";

const defaultRoles = ["Admin", "Manager", "Warehouse", "Production", "Quality", "Accounting"];

function App() {
  const [token, setToken] = useState(localStorage.getItem("token") || "");
  const [user, setUser] = useState(null);
  const [username, setUsername] = useState("admin");
  const [password, setPassword] = useState("123456");
  const [products, setProducts] = useState([]);
  const [suppliers, setSuppliers] = useState([]);
  const [lots, setLots] = useState([]);
  const [shipments, setShipments] = useState([]);
  const [users, setUsers] = useState([]);
  const [roles, setRoles] = useState(defaultRoles);
  const [haccpChecks, setHaccpChecks] = useState([]);
  const [qualityIssues, setQualityIssues] = useState([]);
  const [qualityActions, setQualityActions] = useState([]);
  const [selectedRole, setSelectedRole] = useState("Warehouse");
  const [selectedUserId, setSelectedUserId] = useState("");
  const [receipt, setReceipt] = useState({ lotNo: "", productId: "", supplierId: "", amount: "", expiryDate: "", sourceRef: "" });
  const [shipment, setShipment] = useState({ shipmentNo: "", customerName: "", lotId: "", qty: "" });

  const isAdmin = useMemo(() => user?.roles?.includes("Admin") || user?.roles?.includes("Manager"), [user]);

  const loadDashboard = async () => {
    if (!token) return;
    try {
      const [p, s, l, sh, h, q, a] = await Promise.all([
        getProducts(),
        getSuppliers(),
        getLots(),
        getShipments(),
        getHaccp(),
        getQualityIssues(),
        getQualityActions()
      ]);
      setProducts(p);
      setSuppliers(s);
      setLots(l);
      setShipments(sh);
      setHaccpChecks(h);
      setQualityIssues(q);
      setQualityActions(a);
      if (isAdmin) {
        const u = await getUsers();
        const r = await getRoles();
        setUsers(u);
        setRoles(r.map(x => x.name));
      }
    } catch (err) {
      console.error(err);
    }
  };

  useEffect(() => {
    if (token) loadDashboard();
  }, [token]);

  const handleLogin = async (e) => {
    e.preventDefault();
    try {
      const result = await login(username, password);
      localStorage.setItem("token", result.token);
      setToken(result.token);
      setUser(result.user);
      alert("Giriş başarılı.");
    } catch (err) {
      alert(err.message || "Giriş başarısız.");
    }
  };

  const handleLogout = () => {
    localStorage.removeItem("token");
    setToken("");
    setUser(null);
  };

  const submitReceipt = async (e) => {
    e.preventDefault();
    try {
      await createReceipt({
        lotNo: receipt.lotNo,
        productId: Number(receipt.productId),
        supplierId: receipt.supplierId ? Number(receipt.supplierId) : null,
        amount: Number(receipt.amount),
        unit: "kg",
        expiryDate: receipt.expiryDate || null,
        sourceRef: receipt.sourceRef || null
      });
      alert("Alış kabul kaydedildi.");
      setReceipt({ lotNo: "", productId: products[0]?.id || "", supplierId: suppliers[0]?.id || "", amount: "", expiryDate: "", sourceRef: "" });
      loadDashboard();
    } catch (err) {
      alert(err.message || "Hata oluştu.");
    }
  };

  const submitShipment = async (e) => {
    e.preventDefault();
    try {
      await createShipment({
        shipmentNo: shipment.shipmentNo,
        customerName: shipment.customerName,
        items: [{ lotId: Number(shipment.lotId), qty: Number(shipment.qty) }]
      });
      alert("Sevk oluşturuldu.");
      setShipment({ shipmentNo: "", customerName: "", lotId: "", qty: "" });
      loadDashboard();
    } catch (err) {
      alert(err.message || "Hata oluştu.");
    }
  };

  const assignRole = async () => {
    if (!selectedUserId || !selectedRole) return;
    try {
      await assignUserRole(Number(selectedUserId), selectedRole);
      alert("Rol atandı.");
      loadDashboard();
    } catch (err) {
      alert(err.message || "Rol atanamadı.");
    }
  };

  if (!token) {
    return (
      <div className="login-box">
        <h2>KarkasLot Giriş</h2>
        <form onSubmit={handleLogin}>
          <input value={username} onChange={e => setUsername(e.target.value)} placeholder="Kullanıcı adı" />
          <input type="password" value={password} onChange={e => setPassword(e.target.value)} placeholder="Şifre" />
          <button type="submit">Giriş Yap</button>
        </form>
      </div>
    );
  }

  return (
    <div className="container">
      <header className="topbar">
        <div>
          <h1>KarkasLot</h1>
          <p>Hoş geldin, {user?.fullName || user?.username}</p>
        </div>
        <button className="logout" onClick={handleLogout}>Çıkış</button>
      </header>

      {isAdmin && (
        <section className="panel">
          <h2>Admin Paneli</h2>
          <div className="admin-grid">
            <select value={selectedUserId} onChange={e => setSelectedUserId(e.target.value)}>
              <option value="">Kullanıcı seç</option>
              {users.map(u => <option key={u.id} value={u.id}>{u.username}</option>)}
            </select>
            <select value={selectedRole} onChange={e => setSelectedRole(e.target.value)}>
              {roles.map(r => <option key={r} value={r}>{r}</option>)}
            </select>
            <button onClick={assignRole}>Rol Ata</button>
          </div>
        </section>
      )}

      <section className="cards">
        <div className="card"><strong>{lots.length}</strong><span>Lot</span></div>
        <div className="card"><strong>{shipments.length}</strong><span>Sevk</span></div>
        <div className="card"><strong>{products.length}</strong><span>Ürün</span></div>
      </section>

      <div className="grid">
        <div className="panel">
          <h2>Alış Kabul</h2>
          <form onSubmit={submitReceipt}>
            <input placeholder="Lot numarası" value={receipt.lotNo} onChange={e => setReceipt({ ...receipt, lotNo: e.target.value })} />
            <select value={receipt.productId} onChange={e => setReceipt({ ...receipt, productId: e.target.value })}>
              <option value="">Ürün seç</option>
              {products.map(p => <option key={p.id} value={p.id}>{p.name}</option>)}
            </select>
            <select value={receipt.supplierId} onChange={e => setReceipt({ ...receipt, supplierId: e.target.value })}>
              <option value="">Tedarikçi seç</option>
              {suppliers.map(s => <option key={s.id} value={s.id}>{s.name}</option>)}
            </select>
            <input type="number" min="0.01" step="0.01" placeholder="Miktar" value={receipt.amount} onChange={e => setReceipt({ ...receipt, amount: e.target.value })} />
            <input type="date" value={receipt.expiryDate} onChange={e => setReceipt({ ...receipt, expiryDate: e.target.value })} />
            <input placeholder="İrsaliye / referans" value={receipt.sourceRef} onChange={e => setReceipt({ ...receipt, sourceRef: e.target.value })} />
            <button type="submit">Kaydet</button>
          </form>
        </div>

        <div className="panel">
          <h2>Sevk Oluştur</h2>
          <form onSubmit={submitShipment}>
            <input placeholder="Sevk numarası" value={shipment.shipmentNo} onChange={e => setShipment({ ...shipment, shipmentNo: e.target.value })} />
            <input placeholder="Müşteri adı" value={shipment.customerName} onChange={e => setShipment({ ...shipment, customerName: e.target.value })} />
            <select value={shipment.lotId} onChange={e => setShipment({ ...shipment, lotId: e.target.value })}>
              <option value="">Lot seç</option>
              {lots.filter(x => Number(x.availableQty || 0) > 0).map(x => <option key={x.id} value={x.id}>{x.lotNo} - {x.productName}</option>)}
            </select>
            <input type="number" min="0.01" step="0.01" placeholder="Miktar" value={shipment.qty} onChange={e => setShipment({ ...shipment, qty: e.target.value })} />
            <button type="submit">Sevk Kaydet</button>
          </form>
        </div>
      </div>

      <div className="two-col">
        <section className="panel">
          <h2>Lot Listesi</h2>
          <table>
            <thead>
              <tr><th>Lot</th><th>Ürün</th><th>Mevcut</th><th>Durum</th></tr>
            </thead>
            <tbody>
              {lots.map(lot => (
                <tr key={lot.id}><td>{lot.lotNo}</td><td>{lot.productName}</td><td>{lot.availableQty} {lot.unit}</td><td>{lot.status}</td></tr>
              ))}
            </tbody>
          </table>
        </section>

        <section className="panel">
          <h2>HACCP / Kalite</h2>
          <div className="mini-list">
            <strong>HACCP Kontrolleri:</strong>
            {haccpChecks.length ? haccpChecks.map(x => <div key={x.id}>{x.checkType} - {x.result}</div>) : <div>Henüz kayıt yok.</div>}
          </div>
          <div className="mini-list">
            <strong>Kalite Sorunları:</strong>
            {qualityIssues.length ? qualityIssues.map(x => <div key={x.id}>{x.issueType} - {x.status}</div>) : <div>Henüz kayıt yok.</div>}
          </div>
          <div className="mini-list">
            <strong>Düzeltici Faaliyetler:</strong>
            {qualityActions.length ? qualityActions.map(x => <div key={x.id}>{x.actionText}</div>) : <div>Henüz kayıt yok.</div>}
          </div>
        </section>
      </div>
    </div>
  );
}

export default App;
'@

Write-File (Join-Path $Web "src\index.css") @'
* { box-sizing: border-box; }
body { margin: 0; background: #f3f4f6; font-family: Arial, sans-serif; color: #111827; }
.container { max-width: 1200px; margin: 0 auto; padding: 24px; }
.topbar { display: flex; align-items: center; justify-content: space-between; background: white; padding: 20px; border-radius: 12px; box-shadow: 0 2px 12px rgba(0,0,0,.05); margin-bottom: 20px; }
.login-box { max-width: 420px; margin: 120px auto; background: white; border-radius: 12px; padding: 32px; box-shadow: 0 2px 12px rgba(0,0,0,.05); }
form { display: flex; flex-direction: column; gap: 10px; }
input, select, button { width: 100%; padding: 11px 12px; border-radius: 8px; border: 1px solid #d1d5db; }
button { background: #2563eb; color: white; border: 0; font-weight: 700; cursor: pointer; }
button.logout { max-width: 120px; }
.cards { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; margin-bottom: 20px; }
.card, .panel { background: white; border-radius: 12px; padding: 20px; box-shadow: 0 2px 12px rgba(0,0,0,.04); }
.card { display: flex; flex-direction: column; gap: 8px; }
.card strong { font-size: 34px; color: #2563eb; }
.grid { display: grid; grid-template-columns: repeat(2, minmax(320px, 1fr)); gap: 16px; margin-bottom: 20px; }
.two-col { display: grid; grid-template-columns: 1.15fr 1fr; gap: 16px; }
.admin-grid { display: grid; grid-template-columns: 1fr 1fr auto; gap: 12px; }
.mini-list { display: flex; flex-direction: column; gap: 8px; margin-top: 12px; }
table { width: 100%; border-collapse: collapse; }
th, td { padding: 10px; text-align: left; border-bottom: 1px solid #e5e7eb; }
@media (max-width: 820px) { .cards, .grid, .two-col, .admin-grid { grid-template-columns: 1fr; } }
'@

Push-Location $Web
npm install | Out-Host
Pop-Location

Push-Location $Root
docker compose up -d | Out-Host
Pop-Location

Start-Sleep -Seconds 5
Push-Location $Api
dotnet build | Out-Host
Pop-Location

$zip = Join-Path (Get-Location) "karkaslot.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path $Root -DestinationPath $zip -Force

Write-Host "Kurulum tamamlandı: $zip" -ForegroundColor Green
Write-Host "API çalıştırmak için: cd karkaslot\backend\KarkasLot.Api; dotnet run --urls http://localhost:5159"
Write-Host "Frontend çalıştırmak için: cd karkaslot\frontend\karkaslot-web; npm run dev"
