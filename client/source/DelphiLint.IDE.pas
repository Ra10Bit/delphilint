{
DelphiLint Client for RAD Studio
Copyright (C) 2023 Integrated Application Development

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Lesser General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version.

This program is distributed in the hope that it will be useful, but WITHOUT ANY
WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A
PARTICULAR PURPOSE. See the GNU Lesser General Public License for more details.

You should have received a copy of the GNU General Public License along with
this program. If not, see <https://www.gnu.org/licenses/>.
}
unit DelphiLint.IDE;

interface

uses
    System.SysUtils
  , ToolsAPI
  , Vcl.Dialogs
  , Vcl.Graphics
  , Winapi.Windows
  , System.Classes
  , System.Generics.Collections
  , DelphiLint.Data
  , DockForm
  , DelphiLint.Events
  , DelphiLint.ToolsApiBase
  ;

type

//______________________________________________________________________________________________________________________

  TIDERefreshEvent = procedure(Issues: TArray<TLintIssue>);
  TOnEditorLineChanged = reference to procedure(OldLine: Integer; NewLine: Integer; Data: Integer);

//______________________________________________________________________________________________________________________

  TEditorLineNotifier = class(TEditLineNotifierBase)
  private
    FOnLineChanged: TOnEditorLineChanged;
  public
    constructor Create(OnLineChanged: TOnEditorLineChanged);
    procedure LineChanged(OldLine: Integer; NewLine: Integer; Data: Integer); override;
  end;

//______________________________________________________________________________________________________________________

  TEditorLineTracker = class;

  TChangedLine = record
    FromLine: Integer;
    ToLine: Integer;
    Tracker: TEditorLineTracker;
  end;

//______________________________________________________________________________________________________________________

  TEditorLineTracker = class(TObject)
  private
    FTracker: IOTAEditLineTracker;
    FNotifier: TEditorLineNotifier;
    FPath: string;
    FOnEditorClosed: TEventNotifier<TEditorLineTracker>;
    FOnLineChanged: TEventNotifier<TChangedLine>;

    procedure OnNotifierTriggered(OldLine: Integer; NewLine: Integer; Data: Integer);
  public
    constructor Create(Tracker: IOTAEditLineTracker);
    destructor Destroy; override;

    procedure TrackLine(Line: Integer);
    procedure ClearTracking;

    property OnLineChanged: TEventNotifier<TChangedLine> read FOnLineChanged;
    property OnEditorClosed: TEventNotifier<TEditorLineTracker> read FOnEditorClosed;
    property FilePath: string read FPath;
  end;

//______________________________________________________________________________________________________________________

  TLintEditor = class(TEditorNotifierBase)
  private
    FNotifiers: TList<TNotifierBase>;
    FTrackers: TObjectList<TEditorLineTracker>;
    FInitedViews: TList<IOTAEditView>;

    FOnActiveFileChanged: TEventNotifier<string>;

    procedure OnTrackedLineChanged(const ChangedLine: TChangedLine);

    procedure InitView(const View: IOTAEditView);
    function IsViewInited(const View: IOTAEditView): Boolean;
    procedure OnAnalysisComplete(const Paths: TArray<string>);
  public
    constructor Create;
    destructor Destroy; override;
    procedure ViewNotification(const View: IOTAEditView; Operation: TOperation); override;
    procedure EditorViewActivated(const EditWindow: INTAEditWindow; const EditView: IOTAEditView); override;

    property OnActiveFileChanged: TEventNotifier<string> read FOnActiveFileChanged;
  end;

//______________________________________________________________________________________________________________________

  TLintView = class(TViewNotifierBase)
  private
    FRepaint: Boolean;
    procedure OnAnalysisComplete(const Paths: TArray<string>);
  public
    constructor Create;
    destructor Destroy; override;
    procedure BeginPaint(const View: IOTAEditView; var FullRepaint: Boolean); override;
    procedure PaintLine(const View: IOTAEditView; LineNumber: Integer;
      const LineText: PAnsiChar; const TextWidth: Word; const LineAttributes: TOTAAttributeArray;
      const Canvas: TCanvas; const TextRect: TRect; const LineRect: TRect; const CellSize: TSize); override;
  end;

//______________________________________________________________________________________________________________________

implementation

uses
    System.Math
  , DelphiLint.Context
  , DelphiLint.Logger
  , DelphiLint.Utils
  , DelphiLint.Settings
  ;

//______________________________________________________________________________________________________________________

procedure TEditorLineTracker.ClearTracking;
var
  Index: Integer;
begin
  for Index := FTracker.Count - 1 downto 0 do begin
    FTracker.Delete(Index);
  end;
end;

//______________________________________________________________________________________________________________________

constructor TEditorLineTracker.Create(Tracker: IOTAEditLineTracker);
var
  NotifierIndex: Integer;
begin
  FOnEditorClosed := TEventNotifier<TEditorLineTracker>.Create;
  FOnLineChanged := TEventNotifier<TChangedLine>.Create;
  FPath := Tracker.GetEditBuffer.FileName;
  FTracker := Tracker;

  FNotifier := TEditorLineNotifier.Create(OnNotifierTriggered);
  NotifierIndex := Tracker.AddNotifier(FNotifier);
  FNotifier.OnOwnerFreed.AddListener(
    procedure (const Notf: TNotifierBase) begin
      FNotifier := nil;
      OnEditorClosed.Notify(Self);
    end);
  FNotifier.OnReleased.AddListener(
    procedure (const Notf: TNotifierBase) begin
      FTracker.RemoveNotifier(NotifierIndex);
    end);
end;

//______________________________________________________________________________________________________________________

destructor TEditorLineTracker.Destroy;
begin
  if Assigned(FNotifier) then begin
    FNotifier.Release;
  end;

  FreeAndNil(FOnLineChanged);
  FreeAndNil(FOnEditorClosed);
  inherited;
end;

//______________________________________________________________________________________________________________________

procedure TEditorLineTracker.OnNotifierTriggered(OldLine, NewLine, Data: Integer);
var
  ChangedLine: TChangedLine;
begin
  ChangedLine.FromLine := Data;
  ChangedLine.ToLine := NewLine;
  ChangedLine.Tracker := Self;
  FOnLineChanged.Notify(ChangedLine);
end;

//______________________________________________________________________________________________________________________

procedure TEditorLineTracker.TrackLine(Line: Integer);
begin
  FTracker.AddLine(Line, Line);
end;

//______________________________________________________________________________________________________________________

constructor TEditorLineNotifier.Create(OnLineChanged: TOnEditorLineChanged);
begin
  inherited Create;
  FOnLineChanged := OnLineChanged;
end;

//______________________________________________________________________________________________________________________

procedure TEditorLineNotifier.LineChanged(OldLine, NewLine, Data: Integer);
begin
  FOnLineChanged(OldLine, NewLine, Data);
end;

//______________________________________________________________________________________________________________________

constructor TLintEditor.Create;
begin
  inherited;

  // Once registered with the IDE, notifiers are reference counted
  FNotifiers := TList<TNotifierBase>.Create;
  FTrackers := TObjectList<TEditorLineTracker>.Create;
  FInitedViews := TList<IOTAEditView>.Create;
  FOnActiveFileChanged := TEventNotifier<string>.Create;

  LintContext.OnAnalysisComplete.AddListener(OnAnalysisComplete);

  Log.Info('Editor notifier created');
end;

//______________________________________________________________________________________________________________________

destructor TLintEditor.Destroy;
var
  Notifier: TNotifierBase;
begin
  for Notifier in FNotifiers do begin
    Notifier.Release;
  end;

  if LintContextValid then begin
    LintContext.OnAnalysisComplete.RemoveListener(OnAnalysisComplete);
  end;

  FreeAndNil(FTrackers);
  FreeAndNil(FNotifiers);
  FreeAndNil(FInitedViews);
  FreeAndNil(FOnActiveFileChanged);
  inherited;
end;

//______________________________________________________________________________________________________________________

procedure TLintEditor.EditorViewActivated(const EditWindow: INTAEditWindow; const EditView: IOTAEditView);
begin
  FOnActiveFileChanged.Notify(EditView.Buffer.FileName);

  if not IsViewInited(EditView) then begin
    InitView(EditView);
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintEditor.ViewNotification(const View: IOTAEditView; Operation: TOperation);
begin
  if Operation = opInsert then begin
    InitView(View);
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintEditor.InitView(const View: IOTAEditView);
var
  Tracker: TEditorLineTracker;
  Notifier: TLintView;
  NotifierIndex: Integer;
begin
  Tracker := TEditorLineTracker.Create(View.Buffer.GetEditLineTracker);
  FTrackers.Add(Tracker);
  Tracker.OnLineChanged.AddListener(OnTrackedLineChanged);
  Tracker.OnEditorClosed.AddListener(
    procedure (const Trckr: TEditorLineTracker) begin
      FTrackers.Remove(Trckr);
    end);

  Notifier := TLintView.Create;
  FNotifiers.Add(Notifier);
  NotifierIndex := View.AddNotifier(Notifier);
  Notifier.OnReleased.AddListener(
    procedure(const Notf: TNotifierBase) begin
      View.RemoveNotifier(NotifierIndex);
    end);
  Notifier.OnOwnerFreed.AddListener(
    procedure(const Notf: TNotifierBase) begin
      // Only one notifier per view so this is OK
      FNotifiers.Remove(Notf);
      FInitedViews.Remove(View);
    end);

  FInitedViews.Add(View);
end;

//______________________________________________________________________________________________________________________

function TLintEditor.IsViewInited(const View: IOTAEditView): Boolean;
begin
  Result := FInitedViews.Contains(View);
end;

//______________________________________________________________________________________________________________________

procedure TLintEditor.OnAnalysisComplete(const Paths: TArray<string>);
var
  Tracker: TEditorLineTracker;
  FileIssues: TArray<TLiveIssue>;
  Issue: TLiveIssue;
  SourceEditor: IOTASourceEditor;
begin
  for Tracker in FTrackers do begin
    Tracker.ClearTracking;

    FileIssues := LintContext.GetIssues(Tracker.FilePath);
    for Issue in FileIssues do begin
      Tracker.TrackLine(Issue.StartLine);
      Issue.NewLineMoveSession;
    end;
  end;

  if TryGetCurrentSourceEditor(SourceEditor) and (SourceEditor.EditViewCount <> 0) then begin
    TThread.ForceQueue(
      TThread.Current,
      procedure begin
        SourceEditor.EditViews[0].Paint;
      end);
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintEditor.OnTrackedLineChanged(const ChangedLine: TChangedLine);
begin
  LintContext.UpdateIssueLine(ChangedLine.Tracker.FilePath, ChangedLine.FromLine, ChangedLine.ToLine);
end;

//______________________________________________________________________________________________________________________
//
// TLintView
//
//______________________________________________________________________________________________________________________

constructor TLintView.Create;
begin
  inherited;

  FRepaint := False;
  LintContext.OnAnalysisComplete.AddListener(OnAnalysisComplete);
end;

//______________________________________________________________________________________________________________________

destructor TLintView.Destroy;
begin
  LintContext.OnAnalysisComplete.RemoveListener(OnAnalysisComplete);
  inherited;
end;

//______________________________________________________________________________________________________________________

procedure TLintView.OnAnalysisComplete(const Paths: TArray<string>);
begin
  FRepaint := True;
end;

//______________________________________________________________________________________________________________________

procedure TLintView.BeginPaint(const View: IOTAEditView; var FullRepaint: Boolean);
begin
  if FRepaint then begin
    FullRepaint := True;
    FRepaint := False;
  end;
end;

//______________________________________________________________________________________________________________________

procedure TLintView.PaintLine(const View: IOTAEditView; LineNumber: Integer; const LineText: PAnsiChar;
  const TextWidth: Word; const LineAttributes: TOTAAttributeArray; const Canvas: TCanvas; const TextRect,
  LineRect: TRect; const CellSize: TSize);

  function ColumnToPx(const Col: Integer): Integer;
  begin
    Result := TextRect.Left + (Col + 1 - View.LeftColumn) * CellSize.Width;
  end;

  procedure DrawLine(const StartChar: Integer; const EndChar: Integer; const Color: TColor);
  var
    StartX: Integer;
    EndX: Integer;
  begin
    Canvas.Pen.Color := Color;
    Canvas.Pen.Width := 1;

    StartX := Max(ColumnToPx(StartChar), TextRect.Left);
    EndX := Max(ColumnToPx(EndChar), TextRect.Left);
    if EndChar = -1 then begin
      EndX := TextRect.Right;
    end;

    Canvas.MoveTo(StartX, TextRect.Bottom - 1);
    Canvas.LineTo(EndX, TextRect.Bottom - 1);
  end;

  procedure DrawMessage(const Msg: string; const Color: TColor);
  begin
    Canvas.Font.Color := Color;
    Canvas.Brush.Style := bsClear;
    Canvas.TextOut(LineRect.Left + (2 * CellSize.Width), LineRect.Top, '!');
    Canvas.TextOut(TextRect.Right, TextRect.Top, Msg);
  end;

var
  Issues: TArray<TLiveIssue>;
  Issue: TLiveIssue;
  Msg: string;
  StartLineOffset: Integer;
  EndLineOffset: Integer;
  TetheredIssues: Boolean;
  TextColor: TColor;
begin
  Issues := LintContext.GetIssues(View.Buffer.FileName, LineNumber);

  if Length(Issues) > 0 then begin
    if LintSettings.ClientDarkMode then begin
      TextColor := clWebGold;
    end
    else begin
      TextColor := clWebSienna;
    end;


    TetheredIssues := False;
    for Issue in Issues do begin
      Issue.UpdateTether(LineNumber, string(LineText));

      if not Issue.Tethered then begin
        Continue;
      end;

      TetheredIssues := True;
      StartLineOffset := Issue.StartLineOffset;
      EndLineOffset := Issue.EndLineOffset;

      if Issue.StartLine <> LineNumber then begin
        StartLineOffset := 0;
      end;

      if Issue.EndLine <> LineNumber then begin
        EndLineOffset := -1;
      end;

      DrawLine(StartLineOffset, EndLineOffset, TextColor);

      if Issue.StartLine = LineNumber then begin
        Msg := Msg + ' - ' + Issue.Message;
      end;
    end;

    if TetheredIssues then begin
      DrawMessage(Msg, TextColor);
    end;
  end;
end;

end.
