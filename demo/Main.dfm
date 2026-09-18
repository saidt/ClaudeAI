object Form4: TForm4
  Left = 0
  Top = 0
  Caption = 'Form4'
  ClientHeight = 690
  ClientWidth = 1431
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  OnCreate = FormCreate
  TextHeight = 13
  object DBNavigator1: TDBNavigator
    Left = 0
    Top = 0
    Width = 1431
    Height = 25
    DataSource = DataSource1
    Align = alTop
    TabOrder = 0
    ExplicitWidth = 1429
  end
  object FltrDBGrid1: TFltrDBGrid
    Left = 0
    Top = 25
    Width = 1431
    Height = 665
    Align = alClient
    DataSource = DataSource1
    TabOrder = 1
    TitleFont.Charset = DEFAULT_CHARSET
    TitleFont.Color = clWindowText
    TitleFont.Height = -11
    TitleFont.Name = 'Tahoma'
    TitleFont.Style = []
    OptionsEx = [dgxFooter, dgxFilterBar, dgxSort]
    OddColor = 16378073
    SearchColor = 11927035
    FilterColor = 13421823
    CalculatedColor = clMaroon
  end
  object DataSource1: TDataSource
    DataSet = VPFDPagedDataSet1
    Left = 432
    Top = 141
  end
  object FDConnection1: TFDConnection
    Params.Strings = (
      'Database=T'
      'User_Name=DEV'
      'Password=<@H0tSp@tA0'
      'Server=PROD2SRV'
      'ConnectionDef=MSSQL_Demo')
    Connected = True
    LoginPrompt = False
    Left = 628
    Top = 146
  end
  object FDQuery1: TFDQuery
    Connection = FDConnection1
    SQL.Strings = (
      'select * from dbo.ART with (nolock)')
    Left = 712
    Top = 144
  end
  object VPFDPagedDataSet1: TVPFDPagedDataSet
    Connection = FDConnection1
    BaseSQL = 'select * from dbo.CONT_PRN_JRN with (nolock)'
    KeyFields = 'CODE_ART'
    FilterParams = <>
    Left = 320
    Top = 144
  end
end
