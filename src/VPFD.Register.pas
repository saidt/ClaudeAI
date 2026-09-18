unit VPFD.Register;

{-----------------------------------------------------------------------------
  Design-time registration for TVPFDPagedDataSet.
  Add this unit's containing package to the IDE to get the component on the
  palette (page "FireDAC Virtual Paging") and the Fields editor / Object
  Inspector support that comes for free from being a real TDataSet.
-----------------------------------------------------------------------------}

interface

procedure Register;

implementation

uses
  System.Classes, VPFD.PagedDataSet;

procedure Register;
begin
  RegisterComponents('FireDAC Virtual Paging', [TVPFDPagedDataSet]);
end;

end.
