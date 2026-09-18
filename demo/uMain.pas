unit uMain;

{-----------------------------------------------------------------------------
  Demo for TVPFDPagedDataSet (see ..\src\VPFD.PagedDataSet.pas).

  Shows:
   - virtual paged browsing of a (potentially huge) SQL Server table through
     a plain TDBGrid, with smooth scrolling,
   - a server-side filter + sort bar,
   - CRUD (Insert / Post / Cancel / Delete) through the grid,
   - a master/detail pair (Customers -> Orders) both backed by the same
     paging engine.

  All UI is built in code (FormCreate) to keep this file self-contained and
  free of hand-authored DFM control trees. Fill in your own connection
  details in DemoConnection's Params before running (or adapt to use an
  existing TFDConnection from your project).
-----------------------------------------------------------------------------}

interface

uses
  Winapi.Windows, Winapi.Messages, System.SysUtils, System.Variants,
  System.Classes, Vcl.Graphics, Vcl.Controls, Vcl.Forms, Vcl.Dialogs,
  Vcl.StdCtrls, Vcl.ExtCtrls, Vcl.Grids, Vcl.DBGrids, Data.DB,
  FireDAC.Stan.Intf, FireDAC.Stan.Option, FireDAC.Stan.Error,
  FireDAC.Phys.Intf, FireDAC.Stan.Def, FireDAC.Stan.Pool, FireDAC.Stan.Async,
  FireDAC.Phys, FireDAC.Phys.ODBCBase, FireDAC.Phys.ODBC,
  FireDAC.ConsoleUI.Wait, FireDAC.Comp.Client,
  VPFD.PagedDataSet;

type
  TMainForm = class(TForm)
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
  private
    DemoConnection: TFDConnection;

    dsCustomers: TVPFDPagedDataSet;
    srcCustomers: TDataSource;
    gridCustomers: TDBGrid;

    dsOrders: TVPFDPagedDataSet;
    srcOrders: TDataSource;
    gridOrders: TDBGrid;

    edFilter: TEdit;
    edSort: TEdit;
    lblStatus: TLabel;

    procedure BuildUI;
    procedure ConfigureDataSets;

    procedure btnConnectClick(Sender: TObject);
    procedure btnApplyFilterClick(Sender: TObject);
    procedure btnApplySortClick(Sender: TObject);
    procedure btnFirstClick(Sender: TObject);
    procedure btnPriorClick(Sender: TObject);
    procedure btnNextClick(Sender: TObject);
    procedure btnLastClick(Sender: TObject);
    procedure btnInsertClick(Sender: TObject);
    procedure btnDeleteClick(Sender: TObject);
    procedure btnPostClick(Sender: TObject);
    procedure btnCancelClick(Sender: TObject);
    procedure btnLocateClick(Sender: TObject);
    procedure CustomersAfterScroll(DataSet: TDataSet);
    procedure UpdateStatus;
  public
  end;

var
  MainForm: TMainForm;

implementation

{$R *.dfm}

procedure TMainForm.FormCreate(Sender: TObject);
begin
  Caption := 'TVPFDPagedDataSet demo - virtual paged SQL Server browsing';
  Width := 1100;
  Height := 700;
  Position := poScreenCenter;

  // ODBC connection to SQL Server. Either point at a pre-configured DSN:
  //   DemoConnection.Params.Values['DSN'] := 'YourSqlServerDSN';
  // or connect DSN-less, via the SQL Server ODBC/OLE DB driver name
  // installed on this machine (adjust 'ODBC Driver 17 for SQL Server' to
  // whatever driver you have installed):
  DemoConnection := TFDConnection.Create(Self);
  DemoConnection.DriverName := 'ODBC';
  DemoConnection.Params.Values['ODBCAdvanced'] := 'Driver={ODBC Driver 17 for SQL Server};Server=localhost;Database=YourDatabase;Trusted_Connection=Yes;';
  DemoConnection.Params.Values['DriverID'] := 'MSSQL'; // FireDAC's SQL-Server-over-ODBC dialect
  DemoConnection.LoginPrompt := False;

  dsCustomers := TVPFDPagedDataSet.Create(Self);
  srcCustomers := TDataSource.Create(Self);
  dsOrders := TVPFDPagedDataSet.Create(Self);
  srcOrders := TDataSource.Create(Self);

  BuildUI;
  ConfigureDataSets;
end;

procedure TMainForm.FormDestroy(Sender: TObject);
begin
  if dsOrders.Active then dsOrders.Close;
  if dsCustomers.Active then dsCustomers.Close;
end;

procedure TMainForm.ConfigureDataSets;
begin
  // ---- master: Customers, paged 20 rows at a time -----------------------
  dsCustomers.Connection := DemoConnection;
  dsCustomers.BaseSQL := 'SELECT CustomerID, CompanyName, City, Country FROM dbo.Customers';
  dsCustomers.TableName := 'dbo.Customers';
  dsCustomers.KeyFields := 'CustomerID';
  dsCustomers.SortFields := 'CompanyName';
  dsCustomers.PageSize := 20;
  dsCustomers.AfterScroll := CustomersAfterScroll;
  srcCustomers.DataSet := dsCustomers;
  gridCustomers.DataSource := srcCustomers;

  // ---- detail: Orders, filtered by the current customer ------------------
  dsOrders.Connection := DemoConnection;
  dsOrders.BaseSQL := 'SELECT OrderID, CustomerID, OrderDate, TotalAmount FROM dbo.Orders';
  dsOrders.TableName := 'dbo.Orders';
  dsOrders.KeyFields := 'OrderID';
  dsOrders.SortFields := 'OrderDate DESC';
  dsOrders.PageSize := 20;
  dsOrders.MasterSource := srcCustomers;
  dsOrders.MasterFields := 'CustomerID';
  dsOrders.DetailFields := 'CustomerID';
  srcOrders.DataSet := dsOrders;
  gridOrders.DataSource := srcOrders;
end;

procedure TMainForm.btnConnectClick(Sender: TObject);
begin
  try
    if not DemoConnection.Connected then
      DemoConnection.Connected := True;
    dsCustomers.Active := True;
    dsOrders.Active := True;
    UpdateStatus;
  except
    on E: Exception do
      MessageDlg('Could not connect / open: ' + E.Message, mtError, [mbOK], 0);
  end;
end;

procedure TMainForm.btnApplyFilterClick(Sender: TObject);
begin
  dsCustomers.ServerFilter := Trim(edFilter.Text); // e.g.  Country = 'France'
  UpdateStatus;
end;

procedure TMainForm.btnApplySortClick(Sender: TObject);
begin
  dsCustomers.SortFields := Trim(edSort.Text); // e.g.  City, CompanyName
  UpdateStatus;
end;

procedure TMainForm.btnFirstClick(Sender: TObject);
begin
  dsCustomers.First;
end;

procedure TMainForm.btnPriorClick(Sender: TObject);
begin
  dsCustomers.Prior;
end;

procedure TMainForm.btnNextClick(Sender: TObject);
begin
  dsCustomers.Next;
end;

procedure TMainForm.btnLastClick(Sender: TObject);
begin
  dsCustomers.Last;
end;

procedure TMainForm.btnLocateClick(Sender: TObject);
var
  Id: string;
begin
  if InputQuery('Locate', 'CustomerID:', Id) then
    if not dsCustomers.Locate('CustomerID', Id, []) then
      MessageDlg('Not found.', mtInformation, [mbOK], 0);
end;

procedure TMainForm.btnInsertClick(Sender: TObject);
begin
  dsCustomers.Insert;
end;

procedure TMainForm.btnDeleteClick(Sender: TObject);
begin
  if MessageDlg('Delete the current customer?', mtConfirmation, [mbYes, mbNo], 0) = mrYes then
    dsCustomers.Delete;
end;

procedure TMainForm.btnPostClick(Sender: TObject);
begin
  dsCustomers.Post;
  UpdateStatus;
end;

procedure TMainForm.btnCancelClick(Sender: TObject);
begin
  dsCustomers.Cancel;
end;

procedure TMainForm.CustomersAfterScroll(DataSet: TDataSet);
begin
  UpdateStatus;
end;

procedure TMainForm.UpdateStatus;
begin
  if dsCustomers.Active then
    lblStatus.Caption := Format('Record %d of %d (page size %d)',
      [dsCustomers.RecNo, dsCustomers.RecordCount, dsCustomers.PageSize])
  else
    lblStatus.Caption := 'Not connected';
end;

procedure TMainForm.BuildUI;
var
  ToolPanel, NavPanel: TPanel;
  Splitter: TSplitter;
  btn: TButton;
  lbl: TLabel;
begin
  ToolPanel := TPanel.Create(Self);
  ToolPanel.Parent := Self;
  ToolPanel.Align := alTop;
  ToolPanel.Height := 40;
  ToolPanel.BevelOuter := bvNone;

  btn := TButton.Create(Self); btn.Parent := ToolPanel; btn.Left := 8; btn.Top := 6;
  btn.Caption := 'Connect && Open'; btn.Width := 110; btn.OnClick := btnConnectClick;

  lbl := TLabel.Create(Self); lbl.Parent := ToolPanel; lbl.Left := 130; lbl.Top := 12;
  lbl.Caption := 'Filter (SQL WHERE):';

  edFilter := TEdit.Create(Self); edFilter.Parent := ToolPanel; edFilter.Left := 250; edFilter.Top := 8;
  edFilter.Width := 220; edFilter.TextHint := 'e.g. Country = ''France''';

  btn := TButton.Create(Self); btn.Parent := ToolPanel; btn.Left := 478; btn.Top := 6;
  btn.Caption := 'Apply Filter'; btn.Width := 90; btn.OnClick := btnApplyFilterClick;

  lbl := TLabel.Create(Self); lbl.Parent := ToolPanel; lbl.Left := 580; lbl.Top := 12;
  lbl.Caption := 'Sort (SQL ORDER BY):';

  edSort := TEdit.Create(Self); edSort.Parent := ToolPanel; edSort.Left := 710; edSort.Top := 8;
  edSort.Width := 180; edSort.Text := 'CompanyName';

  btn := TButton.Create(Self); btn.Parent := ToolPanel; btn.Left := 896; btn.Top := 6;
  btn.Caption := 'Apply Sort'; btn.Width := 80; btn.OnClick := btnApplySortClick;

  NavPanel := TPanel.Create(Self);
  NavPanel.Parent := Self;
  NavPanel.Align := alTop;
  NavPanel.Height := 40;
  NavPanel.BevelOuter := bvNone;

  btn := TButton.Create(Self); btn.Parent := NavPanel; btn.Left := 8; btn.Top := 6;
  btn.Caption := '|<'; btn.Width := 30; btn.OnClick := btnFirstClick;
  btn := TButton.Create(Self); btn.Parent := NavPanel; btn.Left := 42; btn.Top := 6;
  btn.Caption := '<'; btn.Width := 30; btn.OnClick := btnPriorClick;
  btn := TButton.Create(Self); btn.Parent := NavPanel; btn.Left := 76; btn.Top := 6;
  btn.Caption := '>'; btn.Width := 30; btn.OnClick := btnNextClick;
  btn := TButton.Create(Self); btn.Parent := NavPanel; btn.Left := 110; btn.Top := 6;
  btn.Caption := '>|'; btn.Width := 30; btn.OnClick := btnLastClick;

  btn := TButton.Create(Self); btn.Parent := NavPanel; btn.Left := 154; btn.Top := 6;
  btn.Caption := 'Locate...'; btn.Width := 70; btn.OnClick := btnLocateClick;

  btn := TButton.Create(Self); btn.Parent := NavPanel; btn.Left := 240; btn.Top := 6;
  btn.Caption := 'Insert'; btn.Width := 60; btn.OnClick := btnInsertClick;
  btn := TButton.Create(Self); btn.Parent := NavPanel; btn.Left := 304; btn.Top := 6;
  btn.Caption := 'Delete'; btn.Width := 60; btn.OnClick := btnDeleteClick;
  btn := TButton.Create(Self); btn.Parent := NavPanel; btn.Left := 368; btn.Top := 6;
  btn.Caption := 'Post'; btn.Width := 60; btn.OnClick := btnPostClick;
  btn := TButton.Create(Self); btn.Parent := NavPanel; btn.Left := 432; btn.Top := 6;
  btn.Caption := 'Cancel'; btn.Width := 60; btn.OnClick := btnCancelClick;

  lblStatus := TLabel.Create(Self); lblStatus.Parent := NavPanel; lblStatus.Left := 520; lblStatus.Top := 12;
  lblStatus.Caption := 'Not connected';

  gridOrders := TDBGrid.Create(Self);
  gridOrders.Parent := Self;
  gridOrders.Align := alRight;
  gridOrders.Width := 420;

  Splitter := TSplitter.Create(Self);
  Splitter.Parent := Self;
  Splitter.Align := alRight;

  gridCustomers := TDBGrid.Create(Self);
  gridCustomers.Parent := Self;
  gridCustomers.Align := alClient;
end;

end.
