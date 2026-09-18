program VPFDPagingDemo;

uses
  Vcl.Forms,
  VPFD.PagedDataSet in '..\src\VPFD.PagedDataSet.pas',
  Main in 'Main.pas' {Form4};

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TForm4, Form4);
  Application.Run;
end.
