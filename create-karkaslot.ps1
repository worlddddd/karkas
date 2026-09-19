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

Push-Location (Join-Path $Root "backend")
dotnet new webapi -n KarkasLot.Api --framework net8.0 --no-https --force | Out-Host
Pop-Location

Push-Location $Api
dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL --version 8.0.8 | Out-Host
Pop-Location

Write-File (Join-Path $Api "appsettings.json") @'
{
  "ConnectionStrings": {
    "DefaultConnection": "Host=localhost;Port=5432;Database=karkaslotdb;Username=postgres;Password=postgres"
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
using Microsoft.EntityFrameworkCore;

var builder = WebApplication.CreateBuilder(args);
builder.Services.AddDbContext<AppDbContext>(o => o.UseNpgsql(builder.Configuration.GetConnectionString("DefaultConnection")));
builder.Services.AddCors(o => o.AddPolicy("web", p => p.AllowAnyOrigin().AllowAnyHeader().AllowAnyMethod()));

var app = builder.Build();
app.UseCors("web");

app.MapGet("/api/health", () => Results.Ok(new { status = "ok", application = "KarkasLot.Api" }));
app.MapGet("/api/products", async (AppDbContext db) => await db.Products.OrderBy(x => x.Name).ToListAsync());
app.MapGet("/api/suppliers", async (AppDbContext db) => await db.Suppliers.OrderBy(x => x.Name).ToListAsync());
app.MapGet("/api/lots", async (AppDbContext db) => await db.Lots.Include(x => x.Product).Include(x => x.Supplier).OrderByDescending(x => x.Id).Select(x => new { x.Id, x.LotNo, ProductName = x.Product!.Name, SupplierName = x.Supplier == null ? "" : x.Supplier.Name, x.Amount, x.Unit, x.Status, x.ExpiryDate, AvailableQty = db.StockMovements.Where(m => m.LotId == x.Id).Sum(m => m.MovementType == "IN" ? m.Qty : -m.Qty) }).ToListAsync());

app.MapPost("/api/receipts", async (ReceiptRequest request, AppDbContext db) => {
  if (string.IsNullOrWhiteSpace(request.LotNo) || request.Amount <= 0) return Results.BadRequest("Lot numarası ve pozitif miktar gereklidir.");
  if (await db.Lots.AnyAsync(x => x.LotNo == request.LotNo)) return Results.BadRequest("Lot numarası zaten kayıtlı.");
  if (!await db.Products.AnyAsync(x => x.Id == request.ProductId)) return Results.BadRequest("Ürün bulunamadı.");
  var lot = new Lot { LotNo = request.LotNo.Trim(), ProductId = request.ProductId, SupplierId = request.SupplierId, Amount = request.Amount, Unit = request.Unit ?? "kg", ExpiryDate = request.ExpiryDate, SourceRef = request.SourceRef, Status = "Kullanılabilir" };
  db.Lots.Add(lot);
  await db.SaveChangesAsync();
  db.StockMovements.Add(new StockMovement { LotId = lot.Id, MovementType = "IN", Qty = lot.Amount, RelatedRef = request.SourceRef ?? "receipt" });
  await db.SaveChangesAsync();
  return Results.Ok(lot);
});

app.MapGet("/api/shipments", async (AppDbContext db) => await db.Shipments.Include(x => x.Items!).ThenInclude(x => x.Lot).OrderByDescending(x => x.Id).Select(x => new { x.Id, x.ShipmentNo, x.CustomerName, x.CreatedAt, LotSummary = string.Join(" | ", x.Items!.Select(i => i.Lot!.LotNo + ":" + i.Qty + " kg")) }).ToListAsync());

app.MapPost("/api/shipments", async (ShipmentRequest request, AppDbContext db) => {
  if (string.IsNullOrWhiteSpace(request.ShipmentNo) || string.IsNullOrWhiteSpace(request.CustomerName) || request.Items.Count == 0) return Results.BadRequest("Sevk bilgileri eksik.");
  await using var tx = await db.Database.BeginTransactionAsync();
  var shipment = new Shipment { ShipmentNo = request.ShipmentNo.Trim(), CustomerName = request.CustomerName.Trim() };
  db.Shipments.Add(shipment);
  await db.SaveChangesAsync();
  foreach (var item in request.Items) {
    var lot = await db.Lots.FirstOrDefaultAsync(x => x.Id == item.LotId);
    if (lot == null) return Results.BadRequest("Lot bulunamadı.");
    var available = await db.StockMovements.Where(x => x.LotId == item.LotId).SumAsync(x => x.MovementType == "IN" ? x.Qty : -x.Qty);
    if (item.Qty <= 0 || available < item.Qty) return Results.BadRequest($"{lot.LotNo} için yetersiz stok.");
    db.ShipmentItems.Add(new ShipmentItem { ShipmentId = shipment.Id, LotId = lot.Id, Qty = item.Qty });
    db.StockMovements.Add(new StockMovement { LotId = lot.Id, MovementType = "OUT", Qty = item.Qty, RelatedRef = "shipment:" + shipment.ShipmentNo });
  }
  await db.SaveChangesAsync();
  await tx.CommitAsync();
  return Results.Ok(shipment);
});

app.Run();

public class AppDbContext : DbContext {
  public AppDbContext(DbContextOptions<AppDbContext> options) : base(options) { }
  public DbSet<Product> Products => Set<Product>();
  public DbSet<Supplier> Suppliers => Set<Supplier>();
  public DbSet<Lot> Lots => Set<Lot>();
  public DbSet<StockMovement> StockMovements => Set<StockMovement>();
  public DbSet<Shipment> Shipments => Set<Shipment>();
  public DbSet<ShipmentItem> ShipmentItems => Set<ShipmentItem>();
}
public class Product { public int Id { get; set; } public string Name { get; set; } = ""; public string Unit { get; set; } = "kg"; }
public class Supplier { public int Id { get; set; } public string Name { get; set; } = ""; }
public class Lot { public int Id { get; set; } public string LotNo { get; set; } = ""; public int ProductId { get; set; } public int? SupplierId { get; set; } public decimal Amount { get; set; } public string Unit { get; set; } = "kg"; public string Status { get; set; } = "Kullanılabilir"; public DateTime? ExpiryDate { get; set; } public string? SourceRef { get; set; } public Product? Product { get; set; } public Supplier? Supplier { get; set; } }
public class StockMovement { public int Id { get; set; } public int LotId { get; set; } public string MovementType { get; set; } = "IN"; public decimal Qty { get; set; } public string? RelatedRef { get; set; } public Lot? Lot { get; set; } }
public class Shipment { public int Id { get; set; } public string ShipmentNo { get; set; } = ""; public string CustomerName { get; set; } = ""; public DateTime CreatedAt { get; set; } = DateTime.UtcNow; public ICollection<ShipmentItem>? Items { get; set; } }
public class ShipmentItem { public int Id { get; set; } public int ShipmentId { get; set; } public int LotId { get; set; } public decimal Qty { get; set; } public Shipment? Shipment { get; set; } public Lot? Lot { get; set; } }
public record ReceiptRequest(string LotNo, int ProductId, int? SupplierId, decimal Amount, string? Unit, DateTime? ExpiryDate, string? SourceRef);
public record ShipmentRequest(string ShipmentNo, string CustomerName, List<ShipmentItemRequest> Items);
public record ShipmentItemRequest(int LotId, decimal Qty);
'@

Push-Location (Join-Path $Root "frontend")
npm create vite@latest karkaslot-web -- --template react | Out-Host
Pop-Location

Write-File (Join-Path $Web "src\services\api.js") @'
const API = "http://localhost:5159/api";
async function request(path, options = {}) {
  const res = await fetch(API + path, { headers: { "Content-Type": "application/json" }, ...options });
  const text = await res.text();
  const data = text ? JSON.parse(text) : null;
  if (!res.ok) throw new Error(typeof data === "string" ? data : "İşlem başarısız.");
  return data;
}
export const getProducts = () => request("/products");
export const getSuppliers = () => request("/suppliers");
export const getLots = () => request("/lots");
export const getShipments = () => request("/shipments");
export const createReceipt = body => request("/receipts", { method: "POST", body: JSON.stringify(body) });
export const createShipment = body => request("/shipments", { method: "POST", body: JSON.stringify(body) });
'@

Write-File (Join-Path $Web "src\App.jsx") @'
import { useEffect, useState } from "react";
import { getProducts, getSuppliers, getLots, getShipments, createReceipt, createShipment } from "./services/api";
import "./index.css";

export default function App() {
  const [products, setProducts] = useState([]), [suppliers, setSuppliers] = useState([]), [lots, setLots] = useState([]), [shipments, setShipments] = useState([]), [error, setError] = useState("");
  const [receipt, setReceipt] = useState({ lotNo: "", productId: "", supplierId: "", amount: "", unit: "kg", expiryDate: "", sourceRef: "" });
  const [shipment, setShipment] = useState({ shipmentNo: "", customerName: "", lotId: "", qty: "" });
  const load = async () => { try { const [p,s,l,sh] = await Promise.all([getProducts(),getSuppliers(),getLots(),getShipments()]); setProducts(p); setSuppliers(s); setLots(l); setShipments(sh); setReceipt(x => ({...x, productId: x.productId || p[0]?.id || "", supplierId: x.supplierId || s[0]?.id || ""})); } catch(e) { setError(e.message); } };
  useEffect(() => { load(); }, []);
  const saveReceipt = async e => { e.preventDefault(); try { await createReceipt({...receipt, productId:Number(receipt.productId), supplierId:receipt.supplierId ? Number(receipt.supplierId) : null, amount:Number(receipt.amount), expiryDate:receipt.expiryDate || null}); alert("Alış kabul kaydedildi."); setReceipt({lotNo:"",productId:products[0]?.id||"",supplierId:suppliers[0]?.id||"",amount:"",unit:"kg",expiryDate:"",sourceRef:""}); load(); } catch(e) { alert(e.message); } };
  const saveShipment = async e => { e.preventDefault(); try { await createShipment({shipmentNo:shipment.shipmentNo,customerName:shipment.customerName,items:[{lotId:Number(shipment.lotId),qty:Number(shipment.qty)}]}); alert("Sevk oluşturuldu."); setShipment({shipmentNo:"",customerName:"",lotId:"",qty:""}); load(); } catch(e) { alert(e.message); } };
  return <main className="container"><h1>KarkasLot</h1><p>Lot/batch bazlı karkas et stok takip</p>{error && <div className="error">{error}</div>}<section className="cards"><div className="card">Lot Sayısı<strong>{lots.length}</strong></div><div className="card">Toplam Stok<strong>{lots.reduce((a,x)=>a+Number(x.availableQty||0),0).toFixed(2)} kg</strong></div><div className="card">Sevk Sayısı<strong>{shipments.length}</strong></div></section><section className="grid"><div className="panel"><h2>Alış Kabul</h2><form onSubmit={saveReceipt}><input required placeholder="Lot numarası" value={receipt.lotNo} onChange={e=>setReceipt({...receipt,lotNo:e.target.value})}/><select required value={receipt.productId} onChange={e=>setReceipt({...receipt,productId:e.target.value})}><option value="">Ürün</option>{products.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select><select value={receipt.supplierId} onChange={e=>setReceipt({...receipt,supplierId:e.target.value})}><option value="">Tedarikçi</option>{suppliers.map(x=><option key={x.id} value={x.id}>{x.name}</option>)}</select><input required type="number" min="0.01" step="0.01" placeholder="Miktar" value={receipt.amount} onChange={e=>setReceipt({...receipt,amount:e.target.value})}/><input type="date" value={receipt.expiryDate} onChange={e=>setReceipt({...receipt,expiryDate:e.target.value})}/><input placeholder="İrsaliye/fatura referansı" value={receipt.sourceRef} onChange={e=>setReceipt({...receipt,sourceRef:e.target.value})}/><button>Kaydet</button></form></div><div className="panel"><h2>Sevk</h2><form onSubmit={saveShipment}><input required placeholder="Sevk numarası" value={shipment.shipmentNo} onChange={e=>setShipment({...shipment,shipmentNo:e.target.value})}/><input required placeholder="Müşteri" value={shipment.customerName} onChange={e=>setShipment({...shipment,customerName:e.target.value})}/><select required value={shipment.lotId} onChange={e=>setShipment({...shipment,lotId:e.target.value})}><option value="">Lot</option>{lots.filter(x=>Number(x.availableQty)>0).sort((a,b)=>(a.expiryDate||"9999").localeCompare(b.expiryDate||"9999")).map(x=><option key={x.id} value={x.id}>{x.lotNo} - {x.availableQty} kg</option>)}</select><input required type="number" min="0.01" step="0.01" placeholder="Miktar" value={shipment.qty} onChange={e=>setShipment({...shipment,qty:e.target.value})}/><button>Sevk Kaydet</button></form></div></section><section className="panel"><h2>Stok</h2><table><thead><tr><th>Lot</th><th>Ürün</th><th>Mevcut</th><th>SKT</th><th>Durum</th></tr></thead><tbody>{lots.map(x=><tr key={x.id}><td>{x.lotNo}</td><td>{x.productName}</td><td>{x.availableQty} {x.unit}</td><td>{x.expiryDate||"-"}</td><td>{x.status}</td></tr>)}</tbody></table></section><section className="panel"><h2>Sevkler</h2>{shipments.map(x=><div className="item" key={x.id}><b>{x.shipmentNo}</b> - {x.customerName}<br/>{x.lotSummary}</div>)}</section></main>;
}
'@

Write-File (Join-Path $Web "src\index.css") @'
*{box-sizing:border-box}body{margin:0;font-family:Arial;background:#f3f5f8;color:#172033}.container{max-width:1200px;margin:auto;padding:24px}.cards,.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:16px;margin:20px 0}.grid{grid-template-columns:repeat(2,1fr)}.card,.panel{background:#fff;border-radius:12px;padding:20px;box-shadow:0 2px 12px #0000000d}.card{display:flex;flex-direction:column;gap:10px}.card strong{font-size:24px;color:#2563eb}form{display:flex;flex-direction:column;gap:10px}input,select,button{padding:11px;border:1px solid #d1d5db;border-radius:8px;font-size:14px}button{background:#2563eb;color:#fff;border:0;font-weight:bold;cursor:pointer}table{width:100%;border-collapse:collapse}th,td{padding:10px;text-align:left;border-bottom:1px solid #e5e7eb}.item{padding:12px;margin-top:8px;background:#fafafa;border:1px solid #e5e7eb;border-radius:8px}.error{padding:12px;background:#fee2e2;color:#991b1b;border-radius:8px}@media(max-width:800px){.cards,.grid{grid-template-columns:1fr}.container{padding:12px}}
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
Write-Host "API: http://localhost:5159/api/health"
Write-Host "Web: http://localhost:5173"
Write-Host "API çalıştırmak için: cd karkaslot\backend\KarkasLot.Api; dotnet run --urls http://localhost:5159"
Write-Host "Frontend çalıştırmak için yeni terminalde: cd karkaslot\frontend\karkaslot-web; npm run dev"
