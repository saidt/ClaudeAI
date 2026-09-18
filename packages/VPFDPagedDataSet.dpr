program VPFDPagedDataSet;

uses
  Vcl.Forms,
  uMain in '..\demo\uMain.pas' {MainForm},
  VPFD.PagedDataSet in '..\src\VPFD.PagedDataSet.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TMainForm, MainForm);
  Application.Run;
end.
