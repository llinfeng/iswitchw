class Chrome
{
   static DebugPort := 9222
   
   /*
      Escape a string in a manner suitable for command line parameters
   */
   CliEscape(Param)
   {
      return """" RegExReplace(Param, "(\\*)""", "$1$1\""") """"
   }
   
   /*
      Finds instances of chrome in debug mode and the ports they're running
      on. If no instances are found, returns a false value. If one or more
      instances are found, returns an associative array where the keys are
      the ports, and the values are the full command line texts used to start
      the processes.
      
      One example of how this may be used would be to open chrome on a
      different port if an instance of chrome is already open on the port
      you wanted to used.
      
      ```
      ; If the wanted port is taken, use the largest taken port plus one
      DebugPort := 9222
      if (Chromes := Chrome.FindInstances()).HasKey(DebugPort)
         DebugPort := Chromes.MaxIndex() + 1
      ChromeInst := new Chrome(ProfilePath,,,, DebugPort)
      ```
      
      Another use would be to scan for running instances and attach to one
      instead of starting a new instance.
      
      ```
      if (Chromes := Chrome.FindInstances())
         ChromeInst := {"base": Chrome, "DebugPort": Chromes.MinIndex(), PID: Chromes[Chromes.MinIndex(), "PID"]}
      else
         ChromeInst := new Chrome(ProfilePath)
      ```
   */
   FindInstances()
   {
      Out := {}
      for Item in ComObjGet("winmgmts:").ExecQuery("SELECT * FROM Win32_Process WHERE Name = 'chrome.exe'")
         if RegExMatch(Item.CommandLine, "i)chrome.exe""?\s+--remote-debugging-port=(\d+)", Match)
            Out[Match1] := {cmd: Item.CommandLine, PID: Item.ProcessId}
      return Out.MaxIndex() ? Out : False
   }
   
   /*
      ProfilePath - Path to the user profile directory to use. Will use the standard if left blank.
      URLs        - The page or array of pages for Chrome to load when it opens
      Flags       - Additional flags for chrome when launching
      ChromePath  - Path to chrome.exe, will detect from start menu when left blank
      DebugPort   - What port should Chrome's remote debugging server run on
   */
   __New(ProfilePath:="", URLs:="about:blank", Flags:="", ChromePath:="", DebugPort:="")
   {
      ; Verify ProfilePath
      if (ProfilePath != "" && !InStr(FileExist(ProfilePath), "D")) {
         throw Exception("The given ProfilePath does not exist")
      } 
      this.ProfilePath := ProfilePath
      
      ; Verify ChromePath
      if (ChromePath == "")
         FileGetShortcut, %A_StartMenuCommon%\Programs\Google Chrome.lnk, ChromePath
      if (ChromePath == "")
         RegRead, ChromePath, HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe
      if !FileExist(ChromePath) {
         throw Exception("Chrome could not be found")
      }
      this.ChromePath := ChromePath
      
      ; Verify DebugPort
      if (DebugPort != "")
      {
         if (DebugPort is not integer) {
            throw Exception("DebugPort must be a positive integer")
         } else if (DebugPort <= 0) {
            throw Exception("DebugPort must be a positive integer")
         }
         this.DebugPort := DebugPort
      }
      
      ; Escape the URL(s)
      for Index, URL in IsObject(URLs) ? URLs : [URLs]
         URLString .= " " this.CliEscape(URL)
      
      Run, % this.CliEscape(ChromePath)
      . " --remote-debugging-port=" this.DebugPort
      . (ProfilePath ? " --user-data-dir=" this.CliEscape(ProfilePath) : "")
      . (Flags ? " " Flags : "")
      . URLString
      ,,, OutputVarPID
      this.PID := OutputVarPID
   }
   
   /*
      End Chrome by terminating the process.
   */
   Kill()
   {
      Process, Close, % this.PID
   }
   
   /*
      Queries chrome for a list of pages that expose a debug interface.
      In addition to standard tabs, these include pages such as extension
      configuration pages.
   */
   GetPageList()
   {
      http := ComObjCreate("WinHttp.WinHttpRequest.5.1")
      http.open("GET", "http://127.0.0.1:" this.DebugPort "/json")
      http.send()
      return LightJson.Parse(http.responseText)
   }
   
   /*
      Returns a connection to the debug interface of a page that matches the
      provided criteria. When multiple pages match the criteria, they appear
      ordered by how recently the pages were opened.
      
      Key        - The key from the page list to search for, such as "url" or "title"
      Value      - The value to search for in the provided key
      MatchMode  - What kind of search to use, such as "exact", "contains", "startswith", or "regex"
      Index      - If multiple pages match the given criteria, which one of them to return
      fnCallback - A function to be called whenever message is received from the page
   */
   GetPageBy(Key, Value, MatchMode:="exact", Index:=1, fnCallback:="")
   {
      Count := 0
      for n, PageData in this.GetPageList()
      {
         if (((MatchMode = "exact" && PageData[Key] = Value) ; Case insensitive
            || (MatchMode = "contains" && InStr(PageData[Key], Value))
            || (MatchMode = "startswith" && InStr(PageData[Key], Value) == 1)
            || (MatchMode = "regex" && PageData[Key] ~= Value))
            && ++Count == Index)
            return new this.Page(PageData.webSocketDebuggerUrl, fnCallback)
      }
   }
   
   /*
      Shorthand for GetPageBy("url", Value, "startswith")
   */
   GetPageByURL(Value, MatchMode:="startswith", Index:=1, fnCallback:="")
   {
      return this.GetPageBy("url", Value, MatchMode, Index, fnCallback)
   }
   
   /*
      Shorthand for GetPageBy("title", Value, "startswith")
   */
   GetPageByTitle(Value, MatchMode:="startswith", Index:=1, fnCallback:="")
   {
      return this.GetPageBy("title", Value, MatchMode, Index, fnCallback)
   }
   
   /*
      Shorthand for GetPageBy("type", Type, "exact")
      
      The default type to search for is "page", which is the visible area of
      a normal Chrome tab.
   */
   GetPage(Index:=1, Type:="page", fnCallback:="")
   {
      return this.GetPageBy("type", Type, "exact", Index, fnCallback)
   }
   
   /*
      Connects to the debug interface of a page given its WebSocket URL.
   */
   class Page
   {
      Connected := False
      ID := 0
      Responses := []
      
      /*
         wsurl      - The desired page's WebSocket URL
         fnCallback - A function to be called whenever message is received
      */
      __New(wsurl, fnCallback:="")
      {
         this.fnCallback := fnCallback
         this.BoundKeepAlive := this.Call.Bind(this, "Browser.getVersion",, False)
         
         ; TODO: Throw exception on invalid objects
         if IsObject(wsurl)
            wsurl := wsurl.webSocketDebuggerUrl
         
         wsurl := StrReplace(wsurl, "localhost", "127.0.0.1")
         this.ws := {"base": this.WebSocket, "_Event": this.Event, "Parent": this}
         this.ws.__New(wsurl)
         
         while !this.Connected {
            Sleep, 50
            If (A_Index > 125) {
               this.Disconnect()
               Exit
            }
         }
      }
      
      /*
         Calls the specified endpoint and provides it with the given
         parameters.
         
         DomainAndMethod - The endpoint domain and method name for the
         endpoint you would like to call. For example:
         PageInst.Call("Browser.close")
         PageInst.Call("Schema.getDomains")
         
         Params - An associative array of parameters to be provided to the
         endpoint. For example:
         PageInst.Call("Page.printToPDF", {"scale": 0.5 ; Numeric Value
         , "landscape": LightJson.true ; Boolean Value
         , "pageRanges: "1-5, 8, 11-13"}) ; String value
         PageInst.Call("Page.navigate", {"url": "https://autohotkey.com/"})
         
         WaitForResponse - Whether to block until a response is received from
         Chrome, which is necessary to receive a return value, or whether
         to continue on with the script without waiting for a response.
      */
      Call(DomainAndMethod, Params:="", WaitForResponse:=True)
      {
         if (!this.Connected) {
            this.Disconnect()
            throw Exception("Not connected to tab")
         }
         
         ; Use a temporary variable for ID in case more calls are made
         ; before we receive a response.
         ID := this.ID += 1
         this.ws.Send(LightJson.Stringify({"id": ID
         , "params": Params ? Params : {}
         , "method": DomainAndMethod}))
         
         if !WaitForResponse
            return
         
         ; Wait for the response
         this.responses[ID] := False
         while !this.responses[ID] {
            Sleep, 50
            If (A_Index > 125)
               Exit
         }
         
         ; Get the response, check if it's an error
         response := this.responses.Delete(ID)
         if (response.error) {
            throw Exception("Chrome indicated error in response",, LightJson.Stringify(response.error))
         }
         
         return response.result
      }
      
      /*
         Run some JavaScript on the page. For example:
         
         PageInst.Evaluate("alert(""I can't believe it's not IE!"");")
         PageInst.Evaluate("document.getElementsByTagName('button')[0].click();")
      */
      Evaluate(JS)
      {
         response := this.Call("Runtime.evaluate",
         ( LTrim Join
         {
            "expression": JS,
            "objectGroup": "console",
            "includeCommandLineAPI": LightJson.true,
            "silent": LightJson.false,
            "returnByValue": LightJson.false,
            "userGesture": LightJson.true,
            "awaitPromise": LightJson.false
         }
         ))
         
         if (response.exceptionDetails) {
            throw Exception(response.result.description,, LightJson.Stringify(response.exceptionDetails))
         }
         
         if (this.Connected = 0) {
            throw Exception("disconnected")
         }

         return response.result
      }
      
      /*
         Waits for the page's readyState to match the DesiredState.
         
         DesiredState - The state to wait for the page's ReadyState to match
         Interval     - How often it should check whether the state matches
      */
      WaitForLoad(DesiredState:="complete", Interval:=100)
      {
         while this.Evaluate("document.readyState").value != DesiredState
            Sleep, Interval
      }
      
      /*
         Internal function triggered when the script receives a message on
         the WebSocket connected to the page.
      */
      Event(EventName, Event)
      {
         ; If it was called from the WebSocket adjust the class context
         if this.Parent
            this := this.Parent
         
         ; TODO: Handle Error events
         if (EventName == "Open")
         {
            this.Connected := True
            BoundKeepAlive := this.BoundKeepAlive
            SetTimer, %BoundKeepAlive%, 15000
         }
         else if (EventName == "Message")
         {
            data := LightJson.Parse(Event.data)
            
            ; Run the callback routine
            fnCallback := this.fnCallback
            if (newData := %fnCallback%(data))
               data := newData
            
            if this.responses.HasKey(data.ID)
               this.responses[data.ID] := data
         }
         else if (EventName == "Close")
         {
            this.Disconnect()
         }
         else if (EventName == "Error")
         {
            throw Exception("Websocket Error!")
         }
      }
      
      /*
         Disconnect from the page's debug interface, allowing the instance
         to be garbage collected.
         
         This method should always be called when you are finished with a
         page or else your script will leak memory.
      */
      Disconnect()
      {
         if !this.Connected
            return
         
         this.Connected := False
         this.ws.Delete("Parent")
         this.ws.Disconnect()
         
         BoundKeepAlive := this.BoundKeepAlive
         SetTimer, %BoundKeepAlive%, Delete
         this.Delete("BoundKeepAlive")
      }
      
      class WebSocket
      {
         __New(WS_URL)
         {
            static wb
            
            ; Create an IE instance
            Gui, +hWndhOld
            Gui, New, +hWndiehWnd
            this.iehWnd := iehWnd
            Gui, Add, ActiveX, vWB, Shell.Explorer
            Gui, %hOld%: Default
            
            ; Write an appropriate document
            WB.Navigate("about:<!DOCTYPE html><meta http-equiv='X-UA-Compatible'"
            . "content='IE=edge'><body></body>")
            while (WB.ReadyState < 4) {
               sleep, 50
               If (A_Index > 150)
                  Exit
            }
            this.document := WB.document
            
            ; Add our handlers to the JavaScript namespace
            this.document.parentWindow.ahk_savews := this._SaveWS.Bind(this)
            this.document.parentWindow.ahk_event := this._Event.Bind(this)
            this.document.parentWindow.ahk_ws_url := WS_URL
            
            ; Add some JavaScript to the page to open a socket
            Script := this.document.createElement("script")
            Script.text := "ws = new WebSocket(ahk_ws_url);`n"
            . "ws.onopen = function(event){ ahk_event('Open', event); };`n"
            . "ws.onclose = function(event){ ahk_event('Close', event); };`n"
            . "ws.onerror = function(event){ ahk_event('Error', event); };`n"
            . "ws.onmessage = function(event){ ahk_event('Message', event); };"
            this.document.body.appendChild(Script)
         }
         
         ; Called by the JS in response to WS events
         _Event(EventName, Event)
         {
            this["On" EventName](Event)
         }
         
         ; Sends data through the WebSocket
         Send(Data)
         {
            this.document.parentWindow.ws.send(Data)
         }
         
         ; Closes the WebSocket connection
         Close(Code:=1000, Reason:="")
         {
            this.document.parentWindow.ws.close(Code, Reason)
         }
         
         ; Closes and deletes the WebSocket, removing
         ; references so the class can be garbage collected
         Disconnect()
         {
            if this.iehWnd
            {
               this.Close()
               Try Gui, % this.iehWnd ": Destroy"
               this.iehWnd := False
            }
         }
      }
   }
}


class LightJson
{
   static JS := LightJson.GetJS(), true := {}, false := {}, null := {}
   
   Parse(json, _rec := false) {
      if !_rec
         obj := this.Parse(this.JS.eval("(" . json . ")"), true)
      else if !IsObject(json)
         obj := json
      else if this.JS.Object.prototype.toString.call(json) == "[object Array]" {
         obj := []
         Loop % json.length
            obj.Push( this.Parse(json[A_Index - 1], true) )
      }
      else {
         obj := {}
         keys := this.JS.Object.keys(json)
         Loop % keys.length {
            k := keys[A_Index - 1]
            obj[k] := this.Parse(json[k], true)
         }
      }
      Return obj
   }
   
   Stringify(obj, indent := "") {
      if indent|1 {
         for k, v in ["true", "false", "null"]
            if (obj = this[v])
               Return v

         if IsObject( obj ) {
            isArray := true
            for key in obj {
               if IsObject(key) {
                  throw Exception("Invalid key")
               }
               if !( key = A_Index || isArray := false )
                  break
            }
            for k, v in obj
               str .= ( A_Index = 1 ? "" : "," ) . ( isArray ? "" : """" . k . """:" ) . this.Stringify(v, true)

            Return isArray ? "[" str "]" : "{" str "}"
         }
         else if !(obj*1 = "" || RegExMatch(obj, "\s"))
            Return obj
         
         for k, v in [["\", "\\"], [A_Tab, "\t"], ["""", "\"""], ["/", "\/"], ["`n", "\n"], ["`r", "\r"], [Chr(12), "\f"], [Chr(8), "\b"]]
            obj := StrReplace( obj, v[1], v[2] )

         Return """" obj """"
      }
      sObj := this.Stringify(obj, true)
      Return this.JS.eval("JSON.stringify(" . sObj . ",'','" . indent . "')")
   }
   
   GetJS() {
      static Doc, JS
      if !Doc {
         Doc := ComObjCreate("htmlfile")
         Doc.write("<meta http-equiv=""X-UA-Compatible"" content=""IE=9"">")
         JS := Doc.parentWindow
         ( Doc.documentMode < 9 && JS.execScript() )
      }
      Return JS
   }
}