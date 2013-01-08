%% @copyright 2013 Zuse Institute Berlin

%   Licensed under the Apache License, Version 2.0 (the "License");
%   you may not use this file except in compliance with the License.
%   You may obtain a copy of the License at
%
%       http://www.apache.org/licenses/LICENSE-2.0
%
%   Unless required by applicable law or agreed to in writing, software
%   distributed under the License is distributed on an "AS IS" BASIS,
%   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%   See the License for the specific language governing permissions and
%   limitations under the License.

%% @author Nico Kruber <kruber@zib.de>
%% @doc Part of replicated DHT implementation.
%%      The test_and_set operation.
%%      This "two-phase" operation uses rdht_tx_read to first read the value
%%      and then alters the tlog entry so that it appears to be a write
%%      operation from rdht_tx_write. Changes are performed in the context of
%%      the client, not on the responsible node(s)!
%% @version $Id$
-module(rdht_tx_test_and_set).
-author('kruber@zib.de').
-vsn('$Id$ ').

%-define(TRACE(X,Y), io:format(X,Y)).
-define(TRACE(X,Y), ok).

-include("scalaris.hrl").
-include("client_types.hrl").

-export([work_phase/3, extract_from_tlog/5]).


-spec work_phase(pid(), rdht_tx:req_id() | rdht_tx_write:req_id(),
                 api_tx:request()) -> ok.
work_phase(ClientPid, ReqId, Request) ->
    rdht_tx_read:work_phase(ClientPid, ReqId, Request).

%% @doc Get a result entry for a test_and_set operation from the given TLog entry.
-spec extract_from_tlog(tx_tlog:tlog_entry(), client_key(),
                        client_value(), client_value(), EnDecode::boolean()) ->
                               {tx_tlog:tlog_entry(), api_tx:testandset_result()}.
extract_from_tlog(Entry, Key, Old, New, EnDecode) ->
    {_, Res0} = rdht_tx_read:extract_from_tlog(Entry, Key, ?read, EnDecode),
    case Res0 of
        {ok, Old} ->
            rdht_tx_write:extract_from_tlog(Entry, Key, New, EnDecode);
        {ok, RealOldValue} when not EnDecode ->
            % maybe there is just a different compression scheme
            % -> test decoded values
            Res0Decoded = rdht_tx:decode_value(RealOldValue),
            OldDecoded = rdht_tx:decode_value(Old),
            if Res0Decoded =:= OldDecoded ->
                   rdht_tx_write:extract_from_tlog(Entry, Key, New, EnDecode);
               true ->
                   {tx_tlog:set_entry_status(Entry, {fail, abort}),
                    {fail, {key_changed, RealOldValue}}}
            end;
        {ok, RealOldValue} ->
            {tx_tlog:set_entry_status(Entry, {fail, abort}),
             {fail, {key_changed, RealOldValue}}};
        X when erlang:is_tuple(X) -> %% other previous error
            {Entry, X}
    end.
