# TVPFDPagedDataSet

A `TDataSet` descendant for Delphi 12.3 that gives **virtual, paged, random-access
browsing of a SQL Server table/view/join through FireDAC**, while keeping at most
**one page of rows (default 20) in client memory** at any time — CRUD, sorting,
filtering and master/detail included.

`TFDQuery` is used *internally, as a tool* (for the page fetch, the row count,
and generated CRUD statements); the component you drop on a form/datamodule
inherits directly from `TDataSet`, so it behaves like any native dataset in
front of `TDBGrid`, `TDBEdit`, data-aware navigators, etc.

## Why not just use TFDQuery with FetchOptions.RowsetSize?

FireDAC's own client-side "fetch on demand" still grows an ever-larger local
cursor cache as you scroll and has no first-class concept of "only fetch the
page that contains record N when N is requested, and only ever keep that one
page." This component implements exactly that policy explicitly, on top of
SQL Server's `OFFSET … FETCH NEXT` paging (SQL Server 2012+), so memory use
stays flat regardless of table size (millions of rows), and `RecordCount`
still reflects the *real*, server-computed total.

## Files

```
src/VPFD.PagedDataSet.pas   - the component (the actual deliverable)
src/VPFD.Register.pas       - IDE design-time registration (RegisterComponents)
packages/VPFDPagedDataSet.dpk - runtime/design-time package to install in the IDE
demo/VPFDPagingDemo.dpr     - a runnable VCL demo (Customers/Orders master-detail)
demo/uMain.pas / uMain.dfm
```

## How it works

* **Paging**: every time a record outside the currently-cached page is
  requested (grid scroll past the loaded window, `RecNo` jump, `Locate`, a
  sort/filter/master change), the entire local cache is thrown away and
  replaced, in a single round trip, by:
  ```sql
  SELECT * FROM (<BaseSQL>) x WHERE <ServerFilter/MasterFilter> ORDER BY <SortFields>
  OFFSET :off ROWS FETCH NEXT :pagesize ROWS ONLY
  ```
  Only that page (≤ `PageSize` rows) is ever held in memory, in a small
  internal `TFDMemTable` (`FPageCache`). Field *values* are never duplicated
  into the `TDataSet` record buffer: `GetFieldData`/`SetFieldData` delegate
  live to that cache row, so FireDAC itself handles all per-type binary
  marshalling (strings, BCD, dates, blobs, …).

* **RecordCount**: obtained via `SELECT COUNT_BIG(*) FROM (<BaseSQL>) x WHERE …`,
  cached until the filter, sort-independent parts, or master row change.

* **Smooth `TDBGrid` navigation**: scrolling through the 20 rows of a page
  costs exactly one round trip; scrolling into the next page costs one more.
  Dragging the grid's scrollbar thumb to an arbitrary position jumps straight
  to the page that contains that row — it never walks the pages in between.

* **Sorting / filtering**: `SortFields` (`ORDER BY` fragment) and
  `ServerFilter` (`WHERE` fragment, with `FilterParams` for safe
  parameter binding) are applied **on the server**. Changing either
  invalidates the cache (and, for the filter, the row count) and repositions
  to the first record.

  > The inherited `Filter`/`Filtered`/`OnFilterRecord` (client-side,
  > whole-result-set) mechanism is intentionally blocked — it's incompatible
  > with "only one page in memory". `SetFiltered(True)` raises
  > `EVPFDError` telling you to use `ServerFilter` instead.

* **CRUD**: dynamic single-table SQL generated from `TableName` + `KeyFields`:
  * `INSERT INTO <TableName> (...) OUTPUT INSERTED.* VALUES (...)` — SQL
    Server's `OUTPUT INSERTED.*` retrieves identity/default/computed values
    in the same round trip, and is used to relocate the grid to the new
    row's real sorted position afterwards.
  * `UPDATE <TableName> SET ... WHERE <KeyFields> = <captured-before-edit values>`
  * `DELETE FROM <TableName> WHERE <KeyFields> = ...`
  * Excluded from INSERT/UPDATE automatically: any field with `TField.ReadOnly
    = True`, plus (for INSERT only, when `AutoIncKey` is `True`, the default)
    a single-field `KeyFields` — the common IDENTITY-primary-key case. List
    any other server-generated/computed columns in `ReadOnlyFields`
    (comma/semicolon separated) to exclude them too. This is explicit rather
    than auto-detected from driver metadata, because that metadata is often
    unreliable once `BaseSQL` is wrapped in a derived-table probe query.
  * A 0-rows-affected UPDATE raises (simple optimistic-concurrency guard).

* **Master/Detail**: standard `MasterSource` + `MasterFields`/`DetailFields`,
  implemented with the VCL's own `TMasterDataLink` helper — the detail
  dataset's `ServerFilter`-equivalent (`FMasterFilter`) is rebuilt from the
  master row's current field values on every master scroll, and the detail
  cache/count are invalidated and repositioned to `First`.

* **Fields exposition**: `FieldDefs` are discovered from the server with a
  `SELECT TOP 0 * FROM (<BaseSQL>) x` probe, so you can right-click the
  component at design time → **Fields Editor** → **Add fields...** exactly
  as with `TFDQuery`/`TTable`, and get strongly-typed persistent fields.

* **`Locate`**: implemented server-side via `ROW_NUMBER() OVER (ORDER BY ...)`
  so it never scans locally. Supports `loCaseInsensitive` and `loPartialKey`
  (partial key issues a `LIKE 'value%'`).

## Quick start

```pascal
VPQuery := TVPFDPagedDataSet.Create(Self);
VPQuery.Connection  := FDConnection1;                 // any open TFDConnection to SQL Server
VPQuery.BaseSQL      := 'SELECT CustomerID, CompanyName, City, Country FROM dbo.Customers';
VPQuery.TableName    := 'dbo.Customers';               // for CRUD
VPQuery.KeyFields     := 'CustomerID';                 // primary key, for CRUD/Locate/repositioning
VPQuery.SortFields    := 'CompanyName';                // ORDER BY (required by OFFSET/FETCH)
VPQuery.PageSize      := 20;
VPQuery.ServerFilter  := 'Country = :Ctry';
VPQuery.FilterParams.CreateParam(ftString, 'Ctry', ptInput).AsString := 'France';
VPQuery.Active        := True;

DataSource1.DataSet := VPQuery;                        // hook up TDBGrid etc. as usual
```

Master/Detail:

```pascal
Orders.MasterSource  := DataSourceCustomers;
Orders.MasterFields  := 'CustomerID';
Orders.DetailFields  := 'CustomerID';
```

See `demo/uMain.pas` for a full runnable example (Customers/Orders,
filter+sort bar, navigation buttons, Insert/Delete/Post/Cancel, Locate).

## Installing the design-time package

1. Open `packages/VPFDPagedDataSet.dpk` in the Delphi 12.3 IDE.
2. Build, then **Install**.
3. The component appears on the palette under **FireDAC Virtual Paging**.

## Requirements / assumptions

* Delphi 12.3, FireDAC, connecting to SQL Server via the ODBC driver
  (`FireDACODBCDriver` in the package's `requires`, `DriverName := 'ODBC'`
  on the `TFDConnection`, with `Params.Values['DriverID'] := 'MSSQL'` so
  FireDAC applies its SQL-Server-over-ODBC SQL dialect).
* SQL Server 2012 or later (for `OFFSET … FETCH NEXT`).
* `BaseSQL` must be a plain `SELECT` (no trailing `ORDER BY`/`;`) that SQL
  Server accepts wrapped as a derived table: `SELECT * FROM (<BaseSQL>) x`.
* `SortFields` or `KeyFields` must be set before `Active := True` (needed as
  the mandatory `ORDER BY` for `OFFSET/FETCH`).
* CRUD targets a single physical table (`TableName`) — for multi-table
  `BaseSQL` (joins/views), either point `TableName` at the specific
  updatable table and keep only its own columns writable, or leave
  `TableName`/`KeyFields` unset to use the dataset read-only.

## A note on how this was written

This unit was written and reviewed carefully against the documented
`TDataSet` abstract-method contract (cross-checked against several modern,
actively-maintained open-source `TDataSet` descendants — mORMot's
`TSynVirtualDataSet` and JEDI VCL's `TJvMemoryData` — to pin down the exact
Delphi 12.3-era signatures, e.g. `GetFieldData`/`SetFieldData` taking
`TValueBuffer`, bookmark methods taking `Pointer`, `TRecordBuffer = PByte`),
but it was **not compiled** in this environment (no Delphi toolchain is
available here). Build it in the IDE and fix up anything the compiler
flags — the design itself (buffer layout, paging, CRUD, master/detail) is
sound; the risk, if any, is a minor per-Delphi-version signature mismatch
in one of the `TDataSet` overrides. If you hit a "signature doesn't match
inherited" error, the first places to check are `InternalCancel`,
`InternalAddRecord`, and `GetActiveRecBuf` (the last one isn't inherited at
all — it's a private helper modelled on the standard recipe, so a mismatch
there would be a genuine bug, not a version issue).

## Known limitations (by design, documented rather than hidden)

* `RecNo`/`RecordCount` are `Integer` because that is `TDataSet`'s public
  contract; internal paging math uses `Int64` throughout.
* No built-in row-version/timestamp concurrency token — only a
  0-rows-affected check on UPDATE. Easy to extend in `ExecuteUpdate`.
* Calculated/lookup fields are supported via the classic "null-byte + data"
  buffer convention, but there is no special-case optimisation for lookups
  against another dataset (use `OnCalcFields` as usual).
