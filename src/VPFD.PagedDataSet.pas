unit VPFD.PagedDataSet;

{-----------------------------------------------------------------------------
  TVPFDPagedDataSet
  ------------------
  A TDataSet descendant that gives virtual/paged, random-access browsing of a
  SQL Server result set through a FireDAC connection (TFDConnection), while
  keeping AT MOST one page of rows (default 20) in client memory at any time.

  Design summary
  --------------
  * TFDQuery is used internally, as a *tool*, not as the ancestor: this class
    inherits directly from TDataSet, so it fully controls buffering.
  * Paging is implemented with SQL Server's OFFSET/FETCH NEXT (requires SQL
    Server 2012+). ORDER BY is mandatory for OFFSET/FETCH, so SortFields (or,
    failing that, KeyFields) is always applied.
  * "Only the last fetched page is in memory": every time a record outside
    the currently cached page is requested (grid scroll past the cached
    window, RecNo jump, Locate, a Sort/Filter change, master row change),
    the whole cache is thrown away and replaced by exactly one fresh page
    fetched in a single round trip (SELECT ... OFFSET .. FETCH NEXT ..).
  * RecordCount is obtained via SELECT COUNT_BIG(*) over the same filtered
    base query and is cached until Filter/MasterFields/BaseSQL change.
  * CRUD is generated dynamically (single table, via TableName + KeyFields)
    and executed through short-lived helper TFDQuery instances; SQL Server's
    OUTPUT INSERTED.* is used to fetch back generated key(s) after INSERT.
  * Master/Detail uses the standard TMasterDataLink helper.
  * "Fields exposition": FieldDefs are discovered from the server (a
    SELECT TOP 0 probe of BaseSQL) so persistent fields can be created at
    design time in the Fields editor exactly as with any TDataSet.

  Buffer layout
  -------------
  Each TDataSet record buffer we hand out is:
    [TVPRecInfo][CalcFieldsSize bytes for calculated/lookup fields]
  TVPRecInfo only carries the record's absolute (0-based) index inside the
  current server-side filtered/sorted result set, plus the bookmark flag.
  Actual field VALUES are never stored in that buffer: GetFieldData /
  SetFieldData delegate live to a small in-memory TFDMemTable that mirrors
  the schema and holds exactly the current page (FPageCache) or, while
  inserting, a single scratch row (FInsertBuffer). This lets FireDAC itself
  handle all the fiddly per-type binary marshalling (strings, BCD, blobs,
  dates...) instead of us reinventing it.

  Known limitations (documented, not silently hidden)
  -----------------------------------------------------
  * RecNo/RecordCount are exposed as Integer because TDataSet's public API
    is Integer-based; internally Int64 is used throughout, so paging math
    itself is correct beyond 2^31 rows even though RecNo positioning would
    not be for such extreme sizes (not a realistic concern in practice).
  * The base TDataSet.Filter/Filtered/OnFilterRecord mechanism is
    intentionally blocked (SetFiltered raises) because client-side,
    whole-result-set filtering is incompatible with "only one page in
    memory". Use the ServerFilter / FilterParams properties instead, which
    are translated into a real SQL WHERE clause.
  * Optimistic concurrency is limited to "0 rows affected => raise"; there
    is no row-version/timestamp column support out of the box (an easy
    extension point in ExecuteUpdate).
  * Locate() is implemented server-side via ROW_NUMBER() and supports
    loCaseInsensitive and loPartialKey (partial key applies LIKE 'value%'
    to each compared field), which covers the common grid "find" scenarios
    but is not a byte-for-byte reimplementation of the VCL's default
    client-side Locate semantics.
-----------------------------------------------------------------------------}

interface

uses
  System.SysUtils, System.Classes, System.Variants, System.Math,
  Data.DB,
  FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Param,
  FireDAC.Stan.Error, FireDAC.Comp.Client;

type
  EVPFDError = class(Exception);

  PVPRecInfo = ^TVPRecInfo;
  TVPRecInfo = record
    Index: Int64;             // absolute 0-based row index in the current
                               // server-side filtered/sorted result set,
                               // or -1 if this buffer does not (yet) map
                               // to a real row (e.g. a fresh insert buffer)
    BookmarkFlag: TBookmarkFlag;
  end;

  TVPFDPagedDataSet = class(TDataSet)
  private
    // ---- configuration -----------------------------------------------
    FConnection: TFDConnection;
    FBaseSQL: string;          // "SELECT col1, col2, ... FROM ... [JOIN ...]"
                                // (no WHERE / ORDER BY / OFFSET)
    FTableName: string;        // physical, single, updatable table for CRUD
    FKeyFields: string;        // comma/semicolon separated primary key field(s)
    FPageSize: Integer;
    FServerFilter: string;     // raw SQL WHERE fragment (no WHERE keyword)
    FSortFields: string;       // raw SQL ORDER BY fragment (no ORDER BY keyword)
    FFilterParams: TParams;    // named params referenced by ServerFilter

    // ---- master/detail --------------------------------------------------
    FMasterLink: TMasterDataLink;
    FMasterFields: string;
    FDetailFields: string;
    FMasterFilter: string;     // SQL fragment derived from the master row

    // ---- engine ---------------------------------------------------------
    FSchemaQuery: TFDQuery;    // one-shot "SELECT TOP 0 * FROM (base) x" probe
    FPageQuery: TFDQuery;      // fetches exactly one page (read-only)
    FPageCache: TFDMemTable;   // holds ONLY the current page (<= PageSize rows)
    FInsertBuffer: TFDMemTable;// scratch single-row table used while dsInsert

    FPageStartIndex: Int64;    // absolute index of row 0 of FPageCache, -1 = none
    FPageRowCount: Integer;    // rows actually present in FPageCache

    FRecordCount: Int64;
    FCountValid: Boolean;

    FCurRec: Int64;            // "cursor": -1 = BOF, RecordCount = EOF
    FActive2: Boolean;

    FOldKeyValuesForEdit: TArray<Variant>;
    FLastInsertedKey: TArray<Variant>;

    procedure SetConnection(const Value: TFDConnection);
    procedure SetBaseSQL(const Value: string);
    procedure SetTableName(const Value: string);
    procedure SetKeyFields(const Value: string);
    procedure SetPageSize(const Value: Integer);
    procedure SetServerFilter(const Value: string);
    procedure SetSortFields(const Value: string);
    function GetMasterSource: TDataSource;
    procedure SetMasterSource(const Value: TDataSource);
    procedure SetMasterFields(const Value: string);
    procedure SetDetailFields(const Value: string);
    procedure MasterChanged(Sender: TObject);
    procedure RebuildMasterFilter;

    function GetKeyFieldArray: TArray<string>;
    function QuoteIdent(const S: string): string;
    function JoinStrings(L: TStrings; const Sep: string): string;
    function BuildWhereClause: string;
    function BuildOrderByClause: string;
    procedure BindFilterParams(Q: TFDQuery);

    procedure DiscoverSchema;
    function EnsureRowInPage(AIndex: Int64): Boolean;
    procedure InvalidateCache;
    procedure InvalidateCount;
    function RealRecordCount: Int64;

    procedure ExecuteInsert(Row: TDataSet);
    procedure ExecuteUpdate(Row: TDataSet; const OldKeyValues: TArray<Variant>);
    procedure ExecuteDelete(const KeyValues: TArray<Variant>);

    function FindAbsoluteIndexByKeyEx(const FieldNames: TArray<string>;
      const Values: TArray<Variant>; Options: TLocateOptions): Int64;
    function FindAbsoluteIndexByKey(const KeyValues: TArray<Variant>): Int64;

    function GetCalcFieldValue(RecBuf: TRecordBuffer; Field: TField;
      var Buffer: TValueBuffer): Boolean;
    procedure SetCalcFieldValue(RecBuf: TRecordBuffer; Field: TField;
      const Buffer: TValueBuffer);
  protected
    // ---- the classic TDataSet abstract-method contract -------------------
    function AllocRecordBuffer: TRecordBuffer; override;
    procedure FreeRecordBuffer(var Buffer: TRecordBuffer); override;
    procedure GetBookmarkData(Buffer: TRecordBuffer; Data: Pointer); override;
    function GetBookmarkFlag(Buffer: TRecordBuffer): TBookmarkFlag; override;
    procedure SetBookmarkFlag(Buffer: TRecordBuffer; Value: TBookmarkFlag); override;
    procedure SetBookmarkData(Buffer: TRecordBuffer; Data: Pointer); override;
    function GetFieldData(Field: TField; var Buffer: TValueBuffer): Boolean; override;
    procedure SetFieldData(Field: TField; Buffer: TValueBuffer); override;
    function GetRecord(Buffer: TRecordBuffer; GetMode: TGetMode; DoCheck: Boolean): TGetResult; override;
    function GetRecordSize: Word; override;
    procedure InternalAddRecord(Buffer: TRecordBuffer; Append: Boolean); override;
    procedure InternalClose; override;
    procedure InternalDelete; override;
    procedure InternalFirst; override;
    procedure InternalGotoBookmark(Bookmark: Pointer); override;
    procedure InternalHandleException; override;
    procedure InternalInitRecord(Buffer: TRecordBuffer); override;
    procedure InternalLast; override;
    procedure InternalOpen; override;
    procedure InternalPost; override;
    procedure InternalSetToRecord(Buffer: TRecordBuffer); override;
    function IsCursorOpen: Boolean; override;
    function GetRecordCount: Integer; override;
    function GetRecNo: Integer; override;
    procedure SetRecNo(Value: Integer); override;
    procedure InternalCancel; override;
    procedure InternalInitFieldDefs; override;

    function GetActiveRecBuf(var RecBuf: TRecordBuffer): Boolean;

    // hooks used to sync the FDMemTable-backed page cache / insert scratch
    // row with our own dsEdit / dsInsert transitions (see unit header)
    procedure DoBeforeEdit; override;
    procedure DoBeforeInsert; override;

    // block the base client-side filter mechanism: it would force scanning
    // (and caching) the whole result set, defeating "only one page in RAM"
    procedure SetFiltered(Value: Boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;

    function Locate(const KeyFields: string; const KeyValues: Variant;
      Options: TLocateOptions): Boolean; override;

    // forces a full requery (cache + count) on next navigation, keeping the
    // dataset open; use e.g. after an external process changed the data
    procedure Refresh;

    property FieldDefs;
  published
    property Connection: TFDConnection read FConnection write SetConnection;
    property BaseSQL: string read FBaseSQL write SetBaseSQL;
    property TableName: string read FTableName write SetTableName;
    property KeyFields: string read FKeyFields write SetKeyFields;
    property PageSize: Integer read FPageSize write SetPageSize default 20;
    property ServerFilter: string read FServerFilter write SetServerFilter;
    property SortFields: string read FSortFields write SetSortFields;
    property FilterParams: TParams read FFilterParams write FFilterParams;

    property MasterSource: TDataSource read GetMasterSource write SetMasterSource;
    property MasterFields: string read FMasterFields write SetMasterFields;
    property DetailFields: string read FDetailFields write SetDetailFields;

    property Active;
    property AutoCalcFields;
    property BeforeOpen;
    property AfterOpen;
    property BeforeClose;
    property AfterClose;
    property BeforeInsert;
    property AfterInsert;
    property BeforeEdit;
    property AfterEdit;
    property BeforePost;
    property AfterPost;
    property BeforeCancel;
    property AfterCancel;
    property BeforeDelete;
    property AfterDelete;
    property BeforeScroll;
    property AfterScroll;
    property BeforeRefresh;
    property AfterRefresh;
    property OnCalcFields;
    property OnNewRecord;
    property OnFilterRecord;
  end;

implementation

uses
  Vcl.Forms;

{ TVPFDPagedDataSet }

constructor TVPFDPagedDataSet.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);

  FPageSize := 20;
  FPageStartIndex := -1;
  FPageRowCount := 0;
  FCurRec := -1;
  FCountValid := False;
  FActive2 := False;

  FFilterParams := TParams.Create(Self);

  FSchemaQuery := TFDQuery.Create(nil);
  FPageQuery := TFDQuery.Create(nil);

  FPageCache := TFDMemTable.Create(nil);
  FInsertBuffer := TFDMemTable.Create(nil);

  FMasterLink := TMasterDataLink.Create(Self);
  FMasterLink.OnMasterChange := MasterChanged;
  FMasterLink.OnMasterDisable := MasterChanged;
end;

destructor TVPFDPagedDataSet.Destroy;
begin
  FMasterLink.Free;
  FInsertBuffer.Free;
  FPageCache.Free;
  FPageQuery.Free;
  FSchemaQuery.Free;
  FFilterParams.Free;
  inherited Destroy;
end;

// ---------------------------------------------------------------------------
// simple property setters
// ---------------------------------------------------------------------------

procedure TVPFDPagedDataSet.SetConnection(const Value: TFDConnection);
begin
  FConnection := Value;
end;

procedure TVPFDPagedDataSet.SetBaseSQL(const Value: string);
begin
  if FBaseSQL <> Value then
  begin
    CheckInactive;
    FBaseSQL := Value;
  end;
end;

procedure TVPFDPagedDataSet.SetTableName(const Value: string);
begin
  FTableName := Value;
end;

procedure TVPFDPagedDataSet.SetKeyFields(const Value: string);
begin
  FKeyFields := Value;
end;

procedure TVPFDPagedDataSet.SetPageSize(const Value: Integer);
begin
  if Value < 1 then
    raise EVPFDError.Create('PageSize must be >= 1.');
  if FPageSize <> Value then
  begin
    FPageSize := Value;
    InvalidateCache;
  end;
end;

procedure TVPFDPagedDataSet.SetServerFilter(const Value: string);
begin
  if FServerFilter <> Value then
  begin
    FServerFilter := Value;
    InvalidateCache;
    InvalidateCount;
    if Active then First;
  end;
end;

procedure TVPFDPagedDataSet.SetSortFields(const Value: string);
begin
  if FSortFields <> Value then
  begin
    FSortFields := Value;
    InvalidateCache;
    if Active then First;
  end;
end;

procedure TVPFDPagedDataSet.SetFiltered(Value: Boolean);
begin
  if Value then
    raise EVPFDError.Create(
      'TVPFDPagedDataSet does not support the client-side Filtered/Filter ' +
      'mechanism (it would require scanning and caching the whole result ' +
      'set). Use the ServerFilter / FilterParams properties instead.');
  inherited SetFiltered(Value);
end;

// ---------------------------------------------------------------------------
// master/detail
// ---------------------------------------------------------------------------

function TVPFDPagedDataSet.GetMasterSource: TDataSource;
begin
  Result := FMasterLink.DataSource;
end;

procedure TVPFDPagedDataSet.SetMasterSource(const Value: TDataSource);
begin
  FMasterLink.DataSource := Value;
end;

procedure TVPFDPagedDataSet.SetMasterFields(const Value: string);
begin
  FMasterFields := Value;
  FMasterLink.FieldNames := Value;
end;

procedure TVPFDPagedDataSet.SetDetailFields(const Value: string);
begin
  if FDetailFields <> Value then
  begin
    FDetailFields := Value;
    RebuildMasterFilter;
    if Active then
    begin
      InvalidateCache;
      InvalidateCount;
      First;
    end;
  end;
end;

procedure TVPFDPagedDataSet.MasterChanged(Sender: TObject);
begin
  RebuildMasterFilter;
  if Active then
  begin
    InvalidateCache;
    InvalidateCount;
    First;
  end;
end;

procedure TVPFDPagedDataSet.RebuildMasterFilter;
var
  MasterNames, DetailNames: TArray<string>;
  Parts: TStringList;
  i: Integer;
  MDS: TDataSet;
  V: Variant;
begin
  FMasterFilter := '';
  if (FMasterLink.DataSource = nil) or (FMasterLink.DataSource.DataSet = nil)
     or (not FMasterLink.DataSource.DataSet.Active)
     or (Trim(FMasterFields) = '') or (Trim(FDetailFields) = '') then
    Exit;

  MDS := FMasterLink.DataSource.DataSet;
  if MDS.IsEmpty then
    Exit;

  MasterNames := FMasterFields.Split([',', ';']);
  DetailNames := FDetailFields.Split([',', ';']);
  if Length(MasterNames) <> Length(DetailNames) then
    raise EVPFDError.Create('MasterFields and DetailFields must list the same number of fields.');

  Parts := TStringList.Create;
  try
    for i := 0 to High(MasterNames) do
    begin
      V := MDS.FieldByName(Trim(MasterNames[i])).Value;
      if VarIsNull(V) then
        Parts.Add(Format('%s IS NULL', [QuoteIdent(Trim(DetailNames[i]))]))
      else if VarIsNumeric(V) then
        Parts.Add(Format('%s = %s', [QuoteIdent(Trim(DetailNames[i])), VarToStr(V)]))
      else
        Parts.Add(Format('%s = ''%s''',
          [QuoteIdent(Trim(DetailNames[i])), StringReplace(VarToStr(V), '''', '''''', [rfReplaceAll])]));
    end;
    FMasterFilter := JoinStrings(Parts, ' AND ');
  finally
    Parts.Free;
  end;
end;

// ---------------------------------------------------------------------------
// SQL building helpers
// ---------------------------------------------------------------------------

function TVPFDPagedDataSet.QuoteIdent(const S: string): string;
begin
  Result := '[' + StringReplace(S, ']', ']]', [rfReplaceAll]) + ']';
end;

function TVPFDPagedDataSet.JoinStrings(L: TStrings; const Sep: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to L.Count - 1 do
  begin
    if i > 0 then
      Result := Result + Sep;
    Result := Result + L[i];
  end;
end;

function TVPFDPagedDataSet.GetKeyFieldArray: TArray<string>;
var
  Parts: TArray<string>;
  i: Integer;
begin
  Parts := FKeyFields.Split([',', ';']);
  SetLength(Result, Length(Parts));
  for i := 0 to High(Parts) do
    Result[i] := Trim(Parts[i]);
end;

function TVPFDPagedDataSet.BuildWhereClause: string;
var
  Parts: TStringList;
begin
  Parts := TStringList.Create;
  try
    if Trim(FServerFilter) <> '' then
      Parts.Add('(' + FServerFilter + ')');
    if Trim(FMasterFilter) <> '' then
      Parts.Add('(' + FMasterFilter + ')');
    if Parts.Count = 0 then
      Exit('');
    Result := 'WHERE ' + JoinStrings(Parts, ' AND ');
  finally
    Parts.Free;
  end;
end;

function TVPFDPagedDataSet.BuildOrderByClause: string;
var
  Effective: string;
begin
  Effective := Trim(FSortFields);
  if Effective = '' then
    Effective := Trim(FKeyFields);
  if Effective = '' then
    raise EVPFDError.Create(
      'SortFields (or, failing that, KeyFields) must be set: SQL Server''s ' +
      'OFFSET/FETCH NEXT paging requires a deterministic ORDER BY.');
  Result := 'ORDER BY ' + Effective;
end;

procedure TVPFDPagedDataSet.BindFilterParams(Q: TFDQuery);
var
  i: Integer;
  P: TParam;
begin
  for i := 0 to FFilterParams.Count - 1 do
  begin
    P := FFilterParams[i];
    if Q.Params.FindParam(P.Name) <> nil then
      Q.ParamByName(P.Name).Value := P.Value;
  end;
end;

// ---------------------------------------------------------------------------
// schema discovery / cache & count invalidation
// ---------------------------------------------------------------------------

procedure TVPFDPagedDataSet.DiscoverSchema;
begin
  FSchemaQuery.Close;
  FSchemaQuery.Connection := FConnection;
  FSchemaQuery.SQL.Text := Format('SELECT TOP 0 * FROM (%s) VPFD_SCHEMA', [FBaseSQL]);
  FSchemaQuery.Open;
end;

procedure TVPFDPagedDataSet.InvalidateCache;
begin
  FPageStartIndex := -1;
  FPageRowCount := 0;
end;

procedure TVPFDPagedDataSet.InvalidateCount;
begin
  FCountValid := False;
end;

function TVPFDPagedDataSet.RealRecordCount: Int64;
begin
  if not FCountValid then
  begin
    var Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConnection;
      Q.SQL.Text := Format('SELECT COUNT_BIG(*) AS VPFD_CNT FROM (%s) VPFD_BASE %s',
        [FBaseSQL, BuildWhereClause]);
      BindFilterParams(Q);
      Q.Open;
      FRecordCount := Q.FieldByName('VPFD_CNT').AsLargeInt;
      Q.Close;
    finally
      Q.Free;
    end;
    FCountValid := True;
  end;
  Result := FRecordCount;
end;

function TVPFDPagedDataSet.EnsureRowInPage(AIndex: Int64): Boolean;
var
  PageStart: Int64;
  SQL: string;
  i: Integer;
begin
  Result := False;
  if AIndex < 0 then
    Exit;

  if (FPageStartIndex >= 0) and (AIndex >= FPageStartIndex)
     and (AIndex < FPageStartIndex + FPageRowCount) then
    Exit(True);

  PageStart := (AIndex div Int64(FPageSize)) * Int64(FPageSize);

  SQL := Format(
    'SELECT * FROM (%s) VPFD_BASE %s %s OFFSET :VPFD_OFF ROWS FETCH NEXT :VPFD_CNT ROWS ONLY',
    [FBaseSQL, BuildWhereClause, BuildOrderByClause]);

  FPageQuery.Close;
  FPageQuery.Connection := FConnection;
  FPageQuery.SQL.Text := SQL;
  BindFilterParams(FPageQuery);
  FPageQuery.ParamByName('VPFD_OFF').DataType := ftLargeint;
  FPageQuery.ParamByName('VPFD_OFF').AsLargeInt := PageStart;
  FPageQuery.ParamByName('VPFD_CNT').DataType := ftInteger;
  FPageQuery.ParamByName('VPFD_CNT').AsInteger := FPageSize;
  FPageQuery.Open;

  if not FPageCache.Active then
  begin
    FPageCache.FieldDefs.Assign(FPageQuery.FieldDefs);
    FPageCache.CreateDataSet;
  end;

  FPageCache.DisableControls;
  try
    while not FPageCache.IsEmpty do
      FPageCache.Delete;
    FPageQuery.First;
    while not FPageQuery.Eof do
    begin
      FPageCache.Append;
      for i := 0 to FPageQuery.FieldCount - 1 do
        FPageCache.Fields[i].Assign(FPageQuery.Fields[i]);
      FPageCache.Post;
      FPageQuery.Next;
    end;
    FPageCache.First;
  finally
    FPageCache.EnableControls;
  end;

  FPageRowCount := FPageQuery.RecordCount;
  FPageStartIndex := PageStart;
  FPageQuery.Close; // only the copied page stays resident, in FPageCache

  Result := (AIndex >= FPageStartIndex) and (AIndex < FPageStartIndex + FPageRowCount);
end;

procedure TVPFDPagedDataSet.Refresh;
begin
  InvalidateCache;
  InvalidateCount;
  if Active then
    First;
end;

// ---------------------------------------------------------------------------
// TDataSet plumbing
// ---------------------------------------------------------------------------

function TVPFDPagedDataSet.AllocRecordBuffer: TRecordBuffer;
begin
  Result := TRecordBuffer(AllocMem(SizeOf(TVPRecInfo) + CalcFieldsSize));
end;

procedure TVPFDPagedDataSet.FreeRecordBuffer(var Buffer: TRecordBuffer);
begin
  FreeMem(Buffer);
  Buffer := nil;
end;

procedure TVPFDPagedDataSet.InternalInitRecord(Buffer: TRecordBuffer);
begin
  FillChar(Buffer^, SizeOf(TVPRecInfo) + CalcFieldsSize, 0);
  PVPRecInfo(Buffer)^.Index := -1;
end;

function TVPFDPagedDataSet.GetRecordSize: Word;
begin
  Result := SizeOf(TVPRecInfo);
end;

function TVPFDPagedDataSet.GetActiveRecBuf(var RecBuf: TRecordBuffer): Boolean;
begin
  case State of
    dsBrowse:
      if IsEmpty then RecBuf := nil else RecBuf := TRecordBuffer(ActiveBuffer);
    dsEdit, dsInsert:
      RecBuf := TRecordBuffer(ActiveBuffer);
    dsCalcFields:
      RecBuf := TRecordBuffer(CalcBuffer);
    dsFilter:
      RecBuf := TRecordBuffer(ActiveBuffer);
    dsNewValue:
      RecBuf := TRecordBuffer(ActiveBuffer);
  else
    RecBuf := nil;
  end;
  Result := RecBuf <> nil;
end;

function TVPFDPagedDataSet.GetBookmarkFlag(Buffer: TRecordBuffer): TBookmarkFlag;
begin
  Result := PVPRecInfo(Buffer)^.BookmarkFlag;
end;

procedure TVPFDPagedDataSet.SetBookmarkFlag(Buffer: TRecordBuffer; Value: TBookmarkFlag);
begin
  PVPRecInfo(Buffer)^.BookmarkFlag := Value;
end;

procedure TVPFDPagedDataSet.GetBookmarkData(Buffer: TRecordBuffer; Data: Pointer);
begin
  PInt64(Data)^ := PVPRecInfo(Buffer)^.Index;
end;

procedure TVPFDPagedDataSet.SetBookmarkData(Buffer: TRecordBuffer; Data: Pointer);
begin
  PVPRecInfo(Buffer)^.Index := PInt64(Data)^;
end;

procedure TVPFDPagedDataSet.InternalGotoBookmark(Bookmark: Pointer);
begin
  FCurRec := PInt64(Bookmark)^;
end;

procedure TVPFDPagedDataSet.InternalSetToRecord(Buffer: TRecordBuffer);
begin
  FCurRec := PVPRecInfo(Buffer)^.Index;
end;

function TVPFDPagedDataSet.GetCalcFieldValue(RecBuf: TRecordBuffer; Field: TField;
  var Buffer: TValueBuffer): Boolean;
var
  P: PByte;
begin
  P := PByte(RecBuf) + SizeOf(TVPRecInfo) + Field.Offset;
  Result := P^ = 1;
  if Result then
    Move((P + 1)^, Buffer[0], Min(Field.DataSize, Length(Buffer)));
end;

procedure TVPFDPagedDataSet.SetCalcFieldValue(RecBuf: TRecordBuffer; Field: TField;
  const Buffer: TValueBuffer);
var
  P: PByte;
begin
  P := PByte(RecBuf) + SizeOf(TVPRecInfo) + Field.Offset;
  if Length(Buffer) = 0 then
    P^ := 0
  else
  begin
    P^ := 1;
    Move(Buffer[0], (P + 1)^, Min(Field.DataSize, Length(Buffer)));
  end;
end;

function TVPFDPagedDataSet.GetFieldData(Field: TField; var Buffer: TValueBuffer): Boolean;
var
  RecBuf: TRecordBuffer;
  Info: PVPRecInfo;
  RowInPage: Int64;
  Src: TFDMemTable;
  SrcField: TField;
  Temp: TValueBuffer;
begin
  Result := False;
  if not GetActiveRecBuf(RecBuf) then
    Exit;

  if Field.FieldKind in [fkCalculated, fkLookup] then
  begin
    Result := GetCalcFieldValue(RecBuf, Field, Buffer);
    Exit;
  end;

  Info := PVPRecInfo(RecBuf);

  if State = dsInsert then
    Src := FInsertBuffer
  else
  begin
    if Info^.Index < 0 then
      Exit(False);
    if not EnsureRowInPage(Info^.Index) then
      Exit(False);
    RowInPage := Info^.Index - FPageStartIndex;
    if FPageCache.RecNo <> RowInPage + 1 then
      FPageCache.RecNo := RowInPage + 1;
    Src := FPageCache;
  end;

  if (not Src.Active) or Src.IsEmpty then
    Exit(False);

  SrcField := Src.FindField(Field.FieldName);
  if SrcField = nil then
    Exit(False);

  SetLength(Temp, SrcField.DataSize);
  Result := SrcField.GetData(Temp, True);
  if Result then
    Move(Temp[0], Buffer[0], Min(Length(Temp), Length(Buffer)));
end;

procedure TVPFDPagedDataSet.SetFieldData(Field: TField; Buffer: TValueBuffer);
var
  RecBuf: TRecordBuffer;
  Src: TFDMemTable;
  DestField: TField;
begin
  if not (State in [dsEdit, dsInsert]) then
    DatabaseError('SetFieldData called outside dsEdit/dsInsert', Self);
  if not GetActiveRecBuf(RecBuf) then
    Exit;

  if Field.FieldKind in [fkCalculated, fkLookup] then
  begin
    SetCalcFieldValue(RecBuf, Field, Buffer);
    DataEvent(deFieldChange, NativeInt(Field));
    Exit;
  end;

  if State = dsInsert then
    Src := FInsertBuffer
  else
    Src := FPageCache;

  DestField := Src.FindField(Field.FieldName);
  if DestField = nil then
    Exit;

  DestField.SetData(Buffer, True);
  DataEvent(deFieldChange, NativeInt(Field));
end;

function TVPFDPagedDataSet.GetRecord(Buffer: TRecordBuffer; GetMode: TGetMode;
  DoCheck: Boolean): TGetResult;
var
  Cnt: Int64;
begin
  Result := grOK;
  Cnt := RealRecordCount;
  case GetMode of
    gmNext:
      begin
        if FCurRec >= Cnt - 1 then
        begin
          Result := grEOF;
          Exit;
        end;
        Inc(FCurRec);
      end;
    gmPrior:
      begin
        if FCurRec <= 0 then
        begin
          Result := grBOF;
          Exit;
        end;
        Dec(FCurRec);
      end;
    gmCurrent:
      begin
        if FCurRec < 0 then
        begin
          Result := grBOF;
          Exit;
        end;
        if FCurRec >= Cnt then
        begin
          Result := grEOF;
          Exit;
        end;
      end;
  end;

  if not EnsureRowInPage(FCurRec) then
  begin
    Result := grError;
    Exit;
  end;

  PVPRecInfo(Buffer)^.Index := FCurRec;
  PVPRecInfo(Buffer)^.BookmarkFlag := bfCurrent;
  if CalcFieldsSize > 0 then
    GetCalcFields(Buffer);
end;

procedure TVPFDPagedDataSet.InternalFirst;
begin
  FCurRec := -1;
end;

procedure TVPFDPagedDataSet.InternalLast;
begin
  FCurRec := RealRecordCount;
end;

function TVPFDPagedDataSet.GetRecNo: Integer;
begin
  UpdateCursorPos;
  if (FCurRec < 0) or IsEmpty then
    Result := 0
  else
    Result := FCurRec + 1;
end;

procedure TVPFDPagedDataSet.SetRecNo(Value: Integer);
begin
  CheckBrowseMode;
  if (Value >= 1) and (Value <= RealRecordCount) then
  begin
    DoBeforeScroll;
    FCurRec := Value - 1;
    Resync([]);
    DoAfterScroll;
  end;
end;

function TVPFDPagedDataSet.GetRecordCount: Integer;
begin
  Result := RealRecordCount;
end;

procedure TVPFDPagedDataSet.InternalInitFieldDefs;
begin
  FieldDefs.Clear;
  if Assigned(FSchemaQuery) and FSchemaQuery.Active then
    FieldDefs.Assign(FSchemaQuery.FieldDefs);
end;

procedure TVPFDPagedDataSet.InternalOpen;
begin
  if not Assigned(FConnection) then
    raise EVPFDError.Create('Connection is not assigned.');
  if Trim(FBaseSQL) = '' then
    raise EVPFDError.Create('BaseSQL is not assigned.');

  DiscoverSchema;

  BookmarkSize := SizeOf(Int64);

  InternalInitFieldDefs;
  if DefaultFields then
    CreateFields;
  BindFields(True);

  FPageCache.Close;
  FPageCache.FieldDefs.Assign(FieldDefs);
  FPageCache.CreateDataSet;

  FPageStartIndex := -1;
  FPageRowCount := 0;
  FCurRec := -1;
  FCountValid := False;
  FActive2 := True;

  RebuildMasterFilter;
end;

procedure TVPFDPagedDataSet.InternalClose;
begin
  BindFields(False);
  if DefaultFields then
    DestroyFields;

  FPageCache.Close;
  FPageQuery.Close;
  FSchemaQuery.Close;
  if FInsertBuffer.Active then
    FInsertBuffer.Close;

  FActive2 := False;
  FPageStartIndex := -1;
  FPageRowCount := 0;
  FCurRec := -1;
  FCountValid := False;
end;

function TVPFDPagedDataSet.IsCursorOpen: Boolean;
begin
  Result := FActive2;
end;

procedure TVPFDPagedDataSet.InternalHandleException;
begin
  if Assigned(Application) then
    Application.HandleException(Self);
end;

// ---------------------------------------------------------------------------
// Edit / Insert / Post / Delete / Cancel
// ---------------------------------------------------------------------------

procedure TVPFDPagedDataSet.DoBeforeEdit;
var
  RecBuf: TRecordBuffer;
  Info: PVPRecInfo;
  KeyNames: TArray<string>;
  i: Integer;
begin
  RecBuf := TRecordBuffer(ActiveBuffer);
  Info := PVPRecInfo(RecBuf);
  if Info^.Index < 0 then
    raise EVPFDError.Create('Cannot edit: no current record.');

  if not EnsureRowInPage(Info^.Index) then
    raise EVPFDError.Create('Cannot edit: record is no longer available (it may have been deleted).');
  FPageCache.RecNo := (Info^.Index - FPageStartIndex) + 1;

  KeyNames := GetKeyFieldArray;
  SetLength(FOldKeyValuesForEdit, Length(KeyNames));
  for i := 0 to High(KeyNames) do
    FOldKeyValuesForEdit[i] := FPageCache.FieldByName(KeyNames[i]).Value;

  FPageCache.Edit;
  inherited DoBeforeEdit;
end;

procedure TVPFDPagedDataSet.DoBeforeInsert;
begin
  FInsertBuffer.Close;
  FInsertBuffer.FieldDefs.Assign(FieldDefs);
  FInsertBuffer.CreateDataSet;
  FInsertBuffer.Append;
  inherited DoBeforeInsert;
end;

procedure TVPFDPagedDataSet.InternalCancel;
begin
  if (State = dsEdit) and (FPageCache.State = dsEdit) then
    FPageCache.Cancel;
  if (State = dsInsert) and FInsertBuffer.Active
     and (FInsertBuffer.State in [dsEdit, dsInsert]) then
    FInsertBuffer.Cancel;
  inherited InternalCancel;
end;

procedure TVPFDPagedDataSet.InternalPost;
var
  RecBuf: TRecordBuffer;
  Info: PVPRecInfo;
  NewIdx: Int64;
begin
  if not GetActiveRecBuf(RecBuf) then
    DatabaseError('No active record to post', Self);
  Info := PVPRecInfo(RecBuf);

  if State = dsInsert then
  begin
    FInsertBuffer.Post;
    ExecuteInsert(FInsertBuffer);

    InvalidateCount;
    InvalidateCache;

    NewIdx := -1;
    if Length(FLastInsertedKey) > 0 then
      NewIdx := FindAbsoluteIndexByKey(FLastInsertedKey);
    if NewIdx < 0 then
      NewIdx := 0;

    FCurRec := NewIdx;
    Info^.Index := NewIdx;
  end
  else
  begin
    FPageCache.Post;
    ExecuteUpdate(FPageCache, FOldKeyValuesForEdit);
    // a server-side default/trigger/computed column may have changed the
    // row, so force a fresh read next time it is accessed
    InvalidateCache;
  end;
end;

procedure TVPFDPagedDataSet.InternalDelete;
var
  RecBuf: TRecordBuffer;
  Info: PVPRecInfo;
  KeyNames: TArray<string>;
  KeyValues: TArray<Variant>;
  i: Integer;
begin
  if not GetActiveRecBuf(RecBuf) then
    Exit;
  Info := PVPRecInfo(RecBuf);
  if Info^.Index < 0 then
    Exit;

  if not EnsureRowInPage(Info^.Index) then
    Exit;
  FPageCache.RecNo := (Info^.Index - FPageStartIndex) + 1;

  KeyNames := GetKeyFieldArray;
  if Length(KeyNames) = 0 then
    raise EVPFDError.Create('KeyFields must be set to perform Delete.');
  SetLength(KeyValues, Length(KeyNames));
  for i := 0 to High(KeyNames) do
    KeyValues[i] := FPageCache.FieldByName(KeyNames[i]).Value;

  ExecuteDelete(KeyValues);

  InvalidateCount;
  InvalidateCache;
end;

procedure TVPFDPagedDataSet.InternalAddRecord(Buffer: TRecordBuffer; Append: Boolean);
begin
  // Standard Insert/Append + Post (used by the grid, by code doing
  // Ds.Insert/Ds.Append + field assignment + Ds.Post) is the supported,
  // exercised path; array-literal AppendRecord()/InsertRecord() calls are
  // therefore just routed through the normal Post pipeline for consistency.
  InternalPost;
end;

// ---------------------------------------------------------------------------
// CRUD SQL generation & execution
// ---------------------------------------------------------------------------

procedure TVPFDPagedDataSet.ExecuteInsert(Row: TDataSet);
var
  Cols, Parms: TStringList;
  KeyNames: TArray<string>;
  i: Integer;
  FD: TFieldDef;
  SQL: string;
  Q: TFDQuery;
begin
  if Trim(FTableName) = '' then
    raise EVPFDError.Create('TableName must be set to perform Insert.');

  Cols := TStringList.Create;
  Parms := TStringList.Create;
  try
    for i := 0 to FieldDefs.Count - 1 do
    begin
      FD := FieldDefs[i];
      if (faAutoGenerate in FD.Attributes) or (faReadonly in FD.Attributes) then
        Continue;
      Cols.Add(QuoteIdent(FD.Name));
      Parms.Add(':' + FD.Name);
    end;
    if Cols.Count = 0 then
      raise EVPFDError.Create('No insertable fields found.');

    SQL := Format('INSERT INTO %s (%s) OUTPUT INSERTED.* VALUES (%s)',
      [FTableName, JoinStrings(Cols, ', '), JoinStrings(Parms, ', ')]);

    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConnection;
      Q.SQL.Text := SQL;
      for i := 0 to FieldDefs.Count - 1 do
      begin
        FD := FieldDefs[i];
        if (faAutoGenerate in FD.Attributes) or (faReadonly in FD.Attributes) then
          Continue;
        Q.ParamByName(FD.Name).Value := Row.FieldByName(FD.Name).Value;
      end;
      Q.Open;
      try
        FLastInsertedKey := nil;
        if not Q.IsEmpty then
        begin
          KeyNames := GetKeyFieldArray;
          SetLength(FLastInsertedKey, Length(KeyNames));
          for i := 0 to High(KeyNames) do
            if Q.FindField(KeyNames[i]) <> nil then
              FLastInsertedKey[i] := Q.FieldByName(KeyNames[i]).Value;
        end;
      finally
        Q.Close;
      end;
    finally
      Q.Free;
    end;
  finally
    Cols.Free;
    Parms.Free;
  end;
end;

procedure TVPFDPagedDataSet.ExecuteUpdate(Row: TDataSet; const OldKeyValues: TArray<Variant>);
var
  SetParts, WhereParts: TStringList;
  KeyNames: TArray<string>;
  i: Integer;
  FD: TFieldDef;
  SQL: string;
  Q: TFDQuery;
begin
  if Trim(FTableName) = '' then
    raise EVPFDError.Create('TableName must be set to perform Update.');
  KeyNames := GetKeyFieldArray;
  if (Length(KeyNames) = 0) or (Length(KeyNames) <> Length(OldKeyValues)) then
    raise EVPFDError.Create('KeyFields must be set to perform Update.');

  SetParts := TStringList.Create;
  WhereParts := TStringList.Create;
  try
    for i := 0 to FieldDefs.Count - 1 do
    begin
      FD := FieldDefs[i];
      if (faAutoGenerate in FD.Attributes) or (faReadonly in FD.Attributes) then
        Continue;
      SetParts.Add(Format('%s = :%s', [QuoteIdent(FD.Name), FD.Name]));
    end;
    if SetParts.Count = 0 then
      Exit; // nothing updatable

    for i := 0 to High(KeyNames) do
      WhereParts.Add(Format('%s = :VPFD_KEY_%d', [QuoteIdent(KeyNames[i]), i]));

    SQL := Format('UPDATE %s SET %s WHERE %s',
      [FTableName, JoinStrings(SetParts, ', '), JoinStrings(WhereParts, ' AND ')]);

    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConnection;
      Q.SQL.Text := SQL;
      for i := 0 to FieldDefs.Count - 1 do
      begin
        FD := FieldDefs[i];
        if (faAutoGenerate in FD.Attributes) or (faReadonly in FD.Attributes) then
          Continue;
        Q.ParamByName(FD.Name).Value := Row.FieldByName(FD.Name).Value;
      end;
      for i := 0 to High(KeyNames) do
        Q.ParamByName('VPFD_KEY_' + IntToStr(i)).Value := OldKeyValues[i];
      Q.ExecSQL;
      if Q.RowsAffected = 0 then
        raise EVPFDError.Create(
          'Update affected 0 rows: the record may have been modified or deleted by another user.');
    finally
      Q.Free;
    end;
  finally
    SetParts.Free;
    WhereParts.Free;
  end;
end;

procedure TVPFDPagedDataSet.ExecuteDelete(const KeyValues: TArray<Variant>);
var
  KeyNames: TArray<string>;
  WhereParts: TStringList;
  i: Integer;
  SQL: string;
  Q: TFDQuery;
begin
  if Trim(FTableName) = '' then
    raise EVPFDError.Create('TableName must be set to perform Delete.');
  KeyNames := GetKeyFieldArray;
  if Length(KeyNames) = 0 then
    raise EVPFDError.Create('KeyFields must be set to perform Delete.');

  WhereParts := TStringList.Create;
  try
    for i := 0 to High(KeyNames) do
      WhereParts.Add(Format('%s = :VPFD_KEY_%d', [QuoteIdent(KeyNames[i]), i]));
    SQL := Format('DELETE FROM %s WHERE %s', [FTableName, JoinStrings(WhereParts, ' AND ')]);

    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConnection;
      Q.SQL.Text := SQL;
      for i := 0 to High(KeyNames) do
        Q.ParamByName('VPFD_KEY_' + IntToStr(i)).Value := KeyValues[i];
      Q.ExecSQL;
    finally
      Q.Free;
    end;
  finally
    WhereParts.Free;
  end;
end;

// ---------------------------------------------------------------------------
// Locate / server-side key -> absolute index resolution (ROW_NUMBER)
// ---------------------------------------------------------------------------

function TVPFDPagedDataSet.FindAbsoluteIndexByKeyEx(const FieldNames: TArray<string>;
  const Values: TArray<Variant>; Options: TLocateOptions): Int64;
var
  WhereParts, SelList: TStringList;
  SQL, Cmp, FName: string;
  Q: TFDQuery;
  i: Integer;
begin
  Result := -1;
  if (Length(FieldNames) = 0) or (Length(FieldNames) <> Length(Values)) then
    Exit;

  WhereParts := TStringList.Create;
  SelList := TStringList.Create;
  try
    for i := 0 to High(FieldNames) do
    begin
      FName := QuoteIdent(FieldNames[i]);
      SelList.Add(FName);

      if VarIsNull(Values[i]) then
        Cmp := Format('%s IS NULL', [FName])
      else if (loPartialKey in Options) and VarIsStr(Values[i]) then
      begin
        if loCaseInsensitive in Options then
          Cmp := Format('UPPER(%s) LIKE UPPER(:VPFD_K%d) + ''%%''', [FName, i])
        else
          Cmp := Format('%s LIKE :VPFD_K%d + ''%%''', [FName, i]);
      end
      else if (loCaseInsensitive in Options) and VarIsStr(Values[i]) then
        Cmp := Format('UPPER(%s) = UPPER(:VPFD_K%d)', [FName, i])
      else
        Cmp := Format('%s = :VPFD_K%d', [FName, i]);

      WhereParts.Add(Cmp);
    end;

    SQL := Format(
      'SELECT TOP 1 rn FROM (SELECT ROW_NUMBER() OVER (%s) - 1 AS rn, %s FROM (%s) VPFD_BASE %s) VPFD_T WHERE %s',
      [BuildOrderByClause, JoinStrings(SelList, ', '), FBaseSQL,
       BuildWhereClause, JoinStrings(WhereParts, ' AND ')]);

    Q := TFDQuery.Create(nil);
    try
      Q.Connection := FConnection;
      Q.SQL.Text := SQL;
      BindFilterParams(Q);
      for i := 0 to High(FieldNames) do
        if not VarIsNull(Values[i]) then
          Q.ParamByName('VPFD_K' + IntToStr(i)).Value := Values[i];
      Q.Open;
      try
        if not Q.IsEmpty then
          Result := Q.Fields[0].AsLargeInt;
      finally
        Q.Close;
      end;
    finally
      Q.Free;
    end;
  finally
    WhereParts.Free;
    SelList.Free;
  end;
end;

function TVPFDPagedDataSet.FindAbsoluteIndexByKey(const KeyValues: TArray<Variant>): Int64;
begin
  Result := FindAbsoluteIndexByKeyEx(GetKeyFieldArray, KeyValues, []);
end;

function TVPFDPagedDataSet.Locate(const KeyFields: string; const KeyValues: Variant;
  Options: TLocateOptions): Boolean;
var
  Names: TArray<string>;
  Values: TArray<Variant>;
  i: Integer;
  Idx: Int64;
begin
  CheckBrowseMode;

  Names := KeyFields.Split([',', ';']);
  for i := 0 to High(Names) do
    Names[i] := Trim(Names[i]);

  SetLength(Values, Length(Names));
  if Length(Names) = 1 then
    Values[0] := KeyValues
  else
    for i := 0 to High(Names) do
      Values[i] := KeyValues[i];

  Idx := FindAbsoluteIndexByKeyEx(Names, Values, Options);
  Result := Idx >= 0;
  if Result then
  begin
    DoBeforeScroll;
    FCurRec := Idx;
    Resync([]);
    DoAfterScroll;
  end;
end;

end.
