%%
%% Copyright (c) 2015 Bas Wegh
%%
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in all
%% copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%% SOFTWARE.
%%

%% @private
-module(erwa_in_ws).
-behaviour(cowboy_websocket).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.



%% for websocket
-export([init/2]).
-export([websocket_handle/3]).
-export([websocket_info/3]).
-export([terminate/3]).

-define(TIMEOUT,60000).

-define(SUBPROTHEADER,<<"sec-websocket-protocol">>).
-define(WSMSGPACK,<<"wamp.2.msgpack">>).
-define(WSJSON,<<"wamp.2.json">>).
-define(WSMSGPACK_BATCHED,<<"wamp.2.msgpack.batched">>).
-define(WSJSON_BATCHED,<<"wamp.2.json.batched">>).


-record(state,{
               enc = undefined,
               ws_enc = undefined,
               length = infitity,
               buffer = <<"">>,
               session = undefined,
               stopping = false
              }).


init( Req, _Opts) ->
  % need to check for the wamp.2.json or wamp.2.msgpack
  {ok, Protocols, Req1} = cowboy_req:parse_header(?SUBPROTHEADER, Req),
  case find_supported_protocol(Protocols) of
      {Enc,WsEncoding,Header} ->
        Req2  = cowboy_req:set_resp_header(?SUBPROTHEADER,Header,Req1),
        Peer = cowboy_req:peer(Req2),
        Session = erwa_session:create(),
        Session1 = erwa_session:set_peer(Peer,Session),
        Session2 = erwa_session:set_source(websocket,Session1),
        {ok,Req2,#state{enc=Enc,ws_enc=WsEncoding,session=Session2}};
      _ ->
        % unsupported
        {shutdown,Req1}
  end.



websocket_handle({WsEnc, Data}, Req, #state{ws_enc=WsEnc,enc=Enc,buffer=Buffer}=State) ->
  {MList,NewBuffer} = wamper_protocol:deserialize(<<Buffer/binary, Data/binary>>,Enc),
  ok = handle_messages(MList),
  {ok,Req,State#state{buffer=NewBuffer}};
websocket_handle(Data, Req, State) ->
  erlang:error(unsupported,[Data,Req,State]),
  {ok, Req, State}.

websocket_info(erwa_stop, Req, State) ->
  {stop,Req,State};
websocket_info(_, Req, #state{stopping=true}=State) ->
  {stop,Req,State};
websocket_info({erwa_in,Msg}, Req, #state{enc=Enc,ws_enc=WsEnc,session=Session}=State) when is_tuple(Msg)->
  case erwa_session:handle_message(Msg, Session) of
    {ok, NewSession} ->
      {ok,Req,State#state{session=NewSession}};
    {reply, OutMsg, NewSession} ->
      {reply,{WsEnc,wamper_protocol:serialize(OutMsg,Enc)},Req,State#state{session=NewSession}};
    {reply_stop, OutMsg, NewSession} ->
      self() ! erwa_stop,
      {reply,{WsEnc,wamper_protocol:serialize(OutMsg,Enc)},Req,State#state{session=NewSession,stopping=true}};
    {stop, NewSession} ->
      {stop,Req,State#state{session=NewSession}}
  end;
websocket_info({erwa_out,Msg}, Req, #state{enc=Enc,ws_enc=WsEnc}=State) when is_tuple(Msg)->
	Reply = wamper_protocol:serialize(Msg,Enc),
	{reply,{WsEnc,Reply},Req,State};

websocket_info(_Data, Req, State) ->
  {ok,Req,State}.

terminate(_Reason, _Req, _State) ->
  ok.


handle_messages([]) ->
  ok;
handle_messages([Msg|Tail]) ->
  self() ! {erwa_in,Msg},
  handle_messages(Tail).



-spec find_supported_protocol([binary()]) -> atom() | {json|json_batched|msgpack|msgpack_batched,text|binary,binary()}.
find_supported_protocol([]) ->
  none;
find_supported_protocol([?WSJSON|_T]) ->
  {json,text,?WSJSON};
find_supported_protocol([?WSJSON_BATCHED|_T]) ->
  {json_batched,text,?WSJSON_BATCHED};
find_supported_protocol([?WSMSGPACK|_T]) ->
  {msgpack,binary,?WSMSGPACK};
find_supported_protocol([?WSMSGPACK_BATCHED|_T]) ->
  {msgpack_batched,binary,?WSMSGPACK_BATCHED};
find_supported_protocol([_|T]) ->
  find_supported_protocol(T).



