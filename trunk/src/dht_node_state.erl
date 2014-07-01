% @copyright 2007-2014 Zuse Institute Berlin

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

%% @author Thorsten Schuett <schuett@zib.de>
%% @doc State of a dht_node.
%% @version $Id$
-module(dht_node_state).
-author('schuett@zib.de').
-vsn('$Id$').

-include("scalaris.hrl").
-include("record_helpers.hrl").

%-define(TRACE(X,Y), log:pal(X,Y)).
-define(TRACE(X,Y), ok).
-define(TRACE_MR_SLIDE(X,Y), ?TRACE(X, Y)).

-export([new/3,
         get/2,
         dump/1,
         set_rt/2, set_rm/2, set_db/2, set_lease_list/2,
         details/1, details/2]).
%% node responsibility:
-export([has_left/1, is_db_responsible/2, is_db_responsible__no_msg_fwd_check/2]).
%% transactions:
-export([set_tx_tp_db/2]).
%% node moves:
-export([get_slide/2, set_slide/3,
         slide_get_data_start_record/2, slide_add_data/2,
         slide_take_delta_stop_record/2, slide_add_delta/2,
         slide_stop_record/3,
         get_split_key/5,
         add_db_range/3, rm_db_range/2]).
%% prbr DBs and states:
-export([get_prbr_state/2]).
-export([set_prbr_state/3]).
%% snapshots
-export([set_snapshot_state/2]).
%% map reduce
-export([set_mr_state/3,
         get_mr_state/2,
         delete_mr_state/2,
         set_mr_master_state/3,
         get_mr_master_state/2,
         delete_mr_master_state/2]).


-ifdef(with_export_type_support).
-export_type([state/0, name/0, db_selector/0, slide_data/0, slide_delta/0]).
-endif.

-type db_selector() :: kv |
                       txid_1 | txid_2 | txid_3 | txid_4 |
                       leases_1 | leases_2 | leases_3 | leases_4.
-type name() :: rt | rt_size | neighbors | succlist | succ | succ_id
              | succ_pid | predlist | pred | pred_id | pred_pid | node
              | node_id | my_range | db_range | succ_range | join_time
              | db | tx_tp_db | proposer | load | slide_pred | slide_succ
              | msg_fwd | rm_state | monitor_proc | prbr_state.

-type slide_snap() :: {snapshot_state:snapshot_state(), db_dht:db_as_list()} | {false}.

-type slide_data() :: {{MovingData::db_dht:db_as_list(), slide_snap()},
                       [{db_selector(), db_prbr:db_as_list()}]}.
-type slide_delta() :: {{ChangedData::db_dht:db_as_list(), DeletedKeys::[?RT:key()]},
                        [{db_selector(), {Changed::db_prbr:db_as_list(),
                                          Deleted::[?RT:key()]}}],
                        {MRDelta::orddict:orddict(),
                         MRMasterDelta::orddict:orddict()}}.

%% userdevguide-begin dht_node_state:state
-record(state, {rt         = ?required(state, rt)        :: ?RT:external_rt(),
                rm_state   = ?required(state, rm_state)  :: rm_loop:state(),
                join_time  = ?required(state, join_time) :: erlang_timestamp(),
                db         = ?required(state, db)        :: db_dht:db(),
                tx_tp_db   = ?required(state, tx_tp_db)  :: any(),
                proposer   = ?required(state, proposer)  :: pid(),
                % slide with pred (must not overlap with 'slide with succ'!):
                slide_pred              = null :: slide_op:slide_op() | null,
                % slide with succ (must not overlap with 'slide with pred'!):
                slide_succ              = null :: slide_op:slide_op() | null,
                % additional range to respond to during a move:
                db_range   = []   :: [{intervals:interval(), slide_op:id()}],
                monitor_proc            = ?required(state, monitor_proc) :: pid(),
                prbr_kv_db = ?required(state, prbr_kv_db) :: prbr:state(),
                txid_db1 = ?required(state, txid_db1) :: prbr:state(),
                txid_db2 = ?required(state, txid_db2) :: prbr:state(),
                txid_db3 = ?required(state, txid_db3) :: prbr:state(),
                txid_db4 = ?required(state, txid_db4) :: prbr:state(),
                lease_db1 = ?required(state, lease_db1) :: prbr:state(),
                lease_db2 = ?required(state, lease_db2) :: prbr:state(),
                lease_db3 = ?required(state, lease_db3) :: prbr:state(),
                lease_db4 = ?required(state, lease_db4) :: prbr:state(),
                lease_list = ?required(state, lease_list) :: lease_list:lease_list(),
                snapshot_state   = null :: snapshot_state:snapshot_state() | null,
                mr_state   = ?required(state, mr_state)  :: orddict:orddict(),
                mr_master_state   = ?required(state, mr_master_state)  :: orddict:orddict()
               }).
-opaque state() :: #state{}.
%% userdevguide-end dht_node_state:state

-spec new(?RT:external_rt(), RMState::rm_loop:state(), db_dht:db()) -> state().
new(RT, RMState, DB) ->
    #state{rt = RT,
           rm_state = RMState,
           join_time = now(),
           db = DB,
           tx_tp_db = tx_tp:init(),
           proposer = pid_groups:get_my(paxos_proposer),
           monitor_proc = pid_groups:get_my(dht_node_monitor),
           prbr_kv_db = prbr:init(prbr_kv_db),
           txid_db1 = prbr:init(txid_db1),
           txid_db2 = prbr:init(txid_db2),
           txid_db3 = prbr:init(txid_db3),
           txid_db4 = prbr:init(txid_db4),
           lease_db1 = prbr:init(lease_db1),
           lease_db2 = prbr:init(lease_db2),
           lease_db3 = prbr:init(lease_db3),
           lease_db4 = prbr:init(lease_db4),
           lease_list = lease_list:empty(),
           snapshot_state = snapshot_state:new(),
           mr_state = orddict:new(),
           mr_master_state = orddict:new()
          }.

%% @doc Gets the given property from the dht_node state.
%%      Allowed keys include:
%%      <ul>
%%        <li>rt = routing table,</li>
%%        <li>rt_size = size of the routing table (provided for convenience),</li>
%%        <li>succlist = successor list,</li>
%%        <li>succ = successor (provided for convenience),</li>
%%        <li>succ_id = ID of the successor (provided for convenience),</li>
%%        <li>succ_pid = PID of the successor (provided for convenience),</li>
%%        <li>predlist = predecessor list,</li>
%%        <li>pred = predecessor (provided for convenience),</li>
%%        <li>pred_id = ID of the predecessor (provided for convenience),</li>
%%        <li>pred_pid = PID of the predecessor (provided for convenience),</li>
%%        <li>node = the own node,</li>
%%        <li>node_id = the ID of the own node (provided for convenience),</li>
%%        <li>my_range = the range of the own node,</li>
%%        <li>succ_range = the range of the successor,</li>
%%        <li>db_range = temporarily added range (during slides),</li>
%%        <li>msg_fwd = temporarily removed range and their current destination (during slides),</li>
%%        <li>full_range = the real responsibility range of the own node (see is_db_responsible/2),</li>
%%        <li>join_time = the time the node was created, i.e. joined the system,</li>
%%        <li>db = DB storing the items,</li>
%%        <li>tx_tp_db = transaction participant DB,</li>
%%        <li>proposer = paxos proposer PID,</li>
%%        <li>load = the load (items) of the own node (provided for convenience).</li>
%%        <li>load2 = the load (see in config lb_active_load_metric) of the own node (provided for convenience).</li>
%%        <li>load3 = the load (see in config lb_active_request_metric) of the own node (provided for convenience).</li>
%%        <li>slide_pred = information about the node's current slide operation with its predecessor.</li>
%%        <li>slide_succ = information about the node's current slide operation with its successor.</li>
%%        <li>snapshot_state = snapshot algorithm state information</li>
%%        <li>lease_list = the list of all leases</li>
%%        <li>mr_state = a dictionary containing all map reduce states currently running on this node</li>
%%      </ul>
%%      Beware of race conditions since the neighborhood may have changed at
%%      the next call.
-spec get(state(), rt) -> ?RT:external_rt();
         (state(), rt_size) -> non_neg_integer();
         (state(), neighbors) -> nodelist:neighborhood();
         (state(), succlist) -> nodelist:non_empty_snodelist();
         (state(), succ) -> node:node_type();
         (state(), succ_id) -> ?RT:key();
         (state(), succ_pid) -> comm:mypid();
         (state(), predlist) -> nodelist:non_empty_snodelist();
         (state(), pred) -> node:node_type();
         (state(), pred_id) -> ?RT:key();
         (state(), pred_pid) -> comm:mypid();
         (state(), node) -> node:node_type();
         (state(), node_id) -> ?RT:key();
         (state(), my_range) -> intervals:interval();
         (state(), db_range) -> [{intervals:interval(), slide_op:id()}];
         (state(), succ_range) -> intervals:interval();
         (state(), full_range) -> intervals:interval();
         (state(), join_time) -> erlang_timestamp();
         (state(), db) -> db_dht:db();
         (state(), tx_tp_db) -> any();
         (state(), proposer) -> pid();
         (state(), load) -> integer();
         (state(), load2) -> unknown | lb_stats:load();
         (state(), load3) -> lb_stats:load();
         (state(), slide_pred) -> slide_op:slide_op() | null;
         (state(), slide_succ) -> slide_op:slide_op() | null;
         (state(), snapshot_state) -> snapshot_state:snapshot_state() | null;
         (state(), msg_fwd) -> [{intervals:interval(), comm:mypid()}];
         (state(), rm_state) -> rm_loop:state();
         (state(), monitor_proc) -> pid();
         (state(), prbr_kv_db) -> prbr:state();
         (state(), txid_db1) -> prbr:state();
         (state(), txid_db2) -> prbr:state();
         (state(), txid_db3) -> prbr:state();
         (state(), txid_db4) -> prbr:state();
         (state(), lease_db1) -> prbr:state();
         (state(), lease_db2) -> prbr:state();
         (state(), lease_db3) -> prbr:state();
         (state(), lease_db4) -> prbr:state();
         (state(), lease_list) -> lease_list:lease_list().
get(#state{rt=RT, rm_state=RMState, join_time=JoinTime,
           db=DB, tx_tp_db=TxTpDb, proposer=Proposer,
           slide_pred=SlidePred, slide_succ=SlideSucc,
           db_range=DBRange, monitor_proc=MonitorProc, prbr_kv_db=PRBRState,
           txid_db1=TxIdDB1, txid_db2=TxIdDB2, txid_db3=TxIdDB3, txid_db4=TxIdDB4,
           lease_db1=LeaseDB1, lease_db2=LeaseDB2, lease_db3=LeaseDB3, lease_db4=LeaseDB4, lease_list=LeaseList,
		   snapshot_state=SnapState} = State, Key) ->
    case Key of
        rt           -> RT;
        rt_size      -> ?RT:get_size(RT);
        neighbors    -> rm_loop:get_neighbors(RMState);
        my_range     -> Neighbors = rm_loop:get_neighbors(RMState),
                        nodelist:node_range(Neighbors);
        db_range     -> DBRange;
        full_range   -> Range1 = lists:foldl(fun({I, _SlideId}, AccI) ->
                                                     intervals:union(AccI, I)
                                             end, get(State, my_range),
                                             DBRange),
                        MsgFwd = get(State, msg_fwd),
                        lists:foldl(fun({FwdInt, _FwdPid}, AccI) ->
                                            intervals:minus(AccI, FwdInt)
                                    end, Range1, MsgFwd);
        succ_range   -> Neighbors = rm_loop:get_neighbors(RMState),
                        nodelist:succ_range(Neighbors);
        msg_fwd      -> MsgFwdPred = slide_op:get_msg_fwd(SlidePred),
                        MsgFwdSucc = slide_op:get_msg_fwd(SlideSucc),
                        if MsgFwdPred =:= [] -> MsgFwdSucc;
                           MsgFwdSucc =:= [] -> MsgFwdPred;
                           true -> lists:append(MsgFwdPred, MsgFwdSucc)
                        end;
        db           -> DB;
        tx_tp_db     -> TxTpDb;
        proposer     -> Proposer;
        slide_pred   -> SlidePred;
        slide_succ   -> SlideSucc;
        rm_state     -> RMState;
        monitor_proc -> MonitorProc;
        snapshot_state -> SnapState;
        succlist     -> nodelist:succs(rm_loop:get_neighbors(RMState));
        succ         -> nodelist:succ(rm_loop:get_neighbors(RMState));
        succ_id      -> node:id(nodelist:succ(rm_loop:get_neighbors(RMState)));
        succ_pid     -> node:pidX(nodelist:succ(rm_loop:get_neighbors(RMState)));
        predlist     -> nodelist:preds(rm_loop:get_neighbors(RMState));
        pred         -> nodelist:pred(rm_loop:get_neighbors(RMState));
        pred_id      -> node:id(nodelist:pred(rm_loop:get_neighbors(RMState)));
        pred_pid     -> node:pidX(nodelist:pred(rm_loop:get_neighbors(RMState)));
        node         -> nodelist:node(rm_loop:get_neighbors(RMState));
        node_id      -> nodelist:nodeid(rm_loop:get_neighbors(RMState));
        join_time    -> JoinTime;
        load         -> db_dht:get_load(DB)
                        %% and the prbr kv entries:
                            + prbr:get_load(PRBRState);
        load2        -> lb_stats:get_load_metric();
        load3        -> lb_stats:get_request_metric();
        prbr_kv_db   -> PRBRState;
        txid_db1     -> TxIdDB1;
        txid_db2     -> TxIdDB2;
        txid_db3     -> TxIdDB3;
        txid_db4     -> TxIdDB4;
        lease_db1    -> LeaseDB1;
        lease_db2    -> LeaseDB2;
        lease_db3    -> LeaseDB3;
        lease_db4    -> LeaseDB4;
        lease_list   -> LeaseList
    end.

-spec get_prbr_state(state(), db_selector()) -> prbr:state().
get_prbr_state(State, WhichDB) ->
    case WhichDB of
        kv -> get(State, prbr_kv_db);
        txid_1 -> get(State, txid_db1);
        txid_2 -> get(State, txid_db2);
        txid_3 -> get(State, txid_db3);
        txid_4 -> get(State, txid_db4);
        leases_1 -> get(State, lease_db1);
        leases_2 -> get(State, lease_db2);
        leases_3 -> get(State, lease_db3);
        leases_4 -> get(State, lease_db4)
    end.

-spec set_prbr_state(state(), db_selector(), prbr:state()) -> state().
set_prbr_state(State, WhichDB, Value) ->
    case WhichDB of
        kv -> State#state{prbr_kv_db = Value};
        %% tx_id ->    State#state{tx_id = Value};
        txid_1 -> State#state{txid_db1 = Value};
        txid_2 -> State#state{txid_db2 = Value};
        txid_3 -> State#state{txid_db3 = Value};
        txid_4 -> State#state{txid_db4 = Value};
        leases_1 -> State#state{lease_db1 = Value};
        leases_2 -> State#state{lease_db2 = Value};
        leases_3 -> State#state{lease_db3 = Value};
        leases_4 -> State#state{lease_db4 = Value}
    end.

-spec set_lease_list(state(), lease_list:lease_list()) -> state().
set_lease_list(State, LeaseList) ->
    State#state{lease_list = LeaseList}.

%% @doc Checks whether the current node has already left the ring, i.e. the has
%%      already changed his ID in order to leave or jump.
-spec has_left(State::state()) -> boolean().
has_left(#state{rm_state=RMState}) ->
    rm_loop:has_left(RMState).

%% @doc Checks whether the node is responsible for the given key either by its
%%      current range or for a range the node is temporarily responsible for
%%      during a slide operation, i.e. we temporarily read/modify data a
%%      neighbor is responsible for but hasn't yet received the data from us.
-spec is_db_responsible(Key::intervals:key(), State::state()) -> boolean().
is_db_responsible(Key, State) ->
    is_db_responsible__no_msg_fwd_check(Key, State) andalso
        lists:all(fun({Interval, _Pid}) ->
                          not intervals:in(Key, Interval)
                  end, get(State, msg_fwd)).

%% @doc Checks whether the node is responsible for the given key either by its
%%      current range or for a range the node is temporarily responsible for
%%      during a slide operation, i.e. we temporarily read/modify data a
%%      neighbor is responsible for but hasn't yet received the data from us.
-spec is_db_responsible__no_msg_fwd_check(Key::intervals:key(), State::state()) -> boolean().
is_db_responsible__no_msg_fwd_check(Key, #state{db_range = DBRange, rm_state = RMState}) ->
    rm_loop:is_responsible(Key, RMState) orelse
        lists:any(fun({Interval, _Id}) ->
                          intervals:in(Key, Interval)
                  end, DBRange).

%% @doc Tries to find a slide operation with the given MoveFullId and returns
%%      it including its type (pred or succ) if successful and its pred/succ
%%      info is correct. Otherwise returns {fail, wrong_pred} if the
%%      predecessor info is wrong (slide with pred) and {fail, wrong_succ} if
%%      the successor info is wrong (slide with succ). If not found,
%%      {fail, not_found} is returned.
-spec get_slide(State::state(), MoveFullId::slide_op:id()) ->
        {Type::pred | succ, SlideOp::slide_op:slide_op()} |
        not_found.
get_slide(#state{slide_pred=SlidePred, slide_succ=SlideSucc}, MoveFullId) ->
    case slide_op:is_slide(SlidePred) andalso
             slide_op:get_id(SlidePred) =:= MoveFullId of
        true -> {pred, SlidePred};
        _ ->
            case slide_op:is_slide(SlideSucc) andalso
                     slide_op:get_id(SlideSucc) =:= MoveFullId of
                true -> {succ, SlideSucc};
                _ -> not_found
            end
    end.

-spec set_tx_tp_db(State::state(), NewTxTpDb::any()) -> state().
set_tx_tp_db(State, DB) -> State#state{tx_tp_db = DB}.

-spec set_db(State::state(), NewDB::db_dht:db()) -> state().
set_db(State, DB) -> State#state{db = DB}.

-spec set_rt(State::state(), NewRT::?RT:external_rt()) -> state().
set_rt(State, RT) -> State#state{rt = RT}.

-spec set_rm(State::state(), NewRMState::rm_loop:state()) -> state().
set_rm(State, RMState) -> State#state{rm_state = RMState}.

-spec set_slide(state(), pred | succ, slide_op:slide_op() | null) -> state().
set_slide(State, pred, SlidePred) -> State#state{slide_pred=SlidePred};
set_slide(State, succ, SlideSucc) -> State#state{slide_succ=SlideSucc}.

-spec set_snapshot_state(State::state(),NewInfo::snapshot_state:snapshot_state()) -> state().
set_snapshot_state(State,NewInfo) -> State#state{snapshot_state=NewInfo}.

-spec get_mr_state(State::state(), mr_state:jobid()) ->
    {value, mr_state:state()} | error.
get_mr_state(#state{mr_state = MRStates}, JobId) ->
    orddict:find(JobId, MRStates).

-spec set_mr_state(State::state(), nonempty_string(), mr_state:state()) -> state().
set_mr_state(#state{mr_state = MRStates} = State, JobId, MRState) ->
    State#state{mr_state = orddict:store(JobId, MRState, MRStates)}.

-spec delete_mr_state(State::state(), nonempty_string()) -> state().
delete_mr_state(#state{mr_state = MRStateList} = State, JobId) ->
    State#state{mr_state = orddict:erase(JobId, MRStateList)}.

-spec get_mr_master_state(State::state(), mr_state:jobid()) -> mr_master_state:state().
get_mr_master_state(#state{mr_master_state = MRMStates}, JobId) ->
    orddict:fetch(JobId, MRMStates).

-spec set_mr_master_state(State::state(), nonempty_string(), mr_master_state:state()) -> state().
set_mr_master_state(#state{mr_master_state = MRMStates} = State, JobId, MRMState) ->
    State#state{mr_master_state = orddict:store(JobId, MRMState, MRMStates)}.

-spec delete_mr_master_state(State::state(), nonempty_string()) -> state().
delete_mr_master_state(#state{mr_master_state = MRMStateList} = State, JobId) ->
    State#state{mr_master_state = orddict:erase(JobId, MRMStateList)}.

-spec add_db_range(State::state(), Interval::intervals:interval(),
                   SlideId::slide_op:id()) -> state().
add_db_range(State = #state{db_range=DBRange}, Interval, SlideId) ->
    ?DBG_ASSERT(not intervals:is_all(Interval)),
    ?TRACE("[ ~.0p ] add_db_range: ~.0p~n", [self(), Interval]),
    State#state{db_range = [{Interval, SlideId} | DBRange]}.

-spec rm_db_range(State::state(), SlideId::slide_op:id()) -> state().
rm_db_range(State = #state{db_range=DBRange}, SlideId) ->
    ?TRACE("[ ~.0p ] rm_db_range: ~.0p~n", [self(), [I || {I, Id} <- DBRange, Id =:= SlideId]]),
    State#state{db_range = [X || X = {_, Id} <- DBRange, Id =/= SlideId]}.

%%% util
-spec dump(state()) -> ok.
dump(State) ->
    io:format("dump <~s,~w> <~s,~w> <~s,~w>~n",
              [get(State, node_id), self(),
               get(State, pred_id), get(State, pred_pid),
               get(State, succ_id), get(State, succ_pid)]),
    ok.

%% @doc Gets the requested details about the current node.
-spec details(state(), [node_details:node_details_name()]) -> node_details:node_details().
details(State, Which) ->
    ExtractValues =
        fun(Elem, NodeDetails) ->
                case Elem of
                    hostname    -> node_details:set(NodeDetails, hostname, net_adm:localhost());
                    message_log -> node_details:set(NodeDetails, message_log, ok);
                    memory      -> node_details:set(NodeDetails, memory, erlang:memory(total));
                    is_leaving  -> node_details:set(NodeDetails, Elem, rm_loop:has_left(get(State, rm_state)));
                    Tag         -> node_details:set(NodeDetails, Tag, get(State, Tag))
                end
        end,
    lists:foldl(ExtractValues, node_details:new(), Which).

%% @doc Gets the following details about the current node:
%%      predecessor and successor lists, the node itself, its load, hostname,
%%      routing table size, memory usage.
-spec details(state()) -> node_details:node_details().
details(State) ->
    Neighbors = get(State, neighbors),
    PredList = nodelist:preds(Neighbors),
    SuccList = nodelist:succs(Neighbors),
    Node = nodelist:node(Neighbors),
    Load = get(State, load),
    Load2 = get(State, load2),
    Load3 = get(State, load3),
    Hostname = net_adm:localhost(),
    RTSize = get(State, rt_size),
    node_details:new(PredList, Node, SuccList, Load, Load2, Load3, Hostname, RTSize, erlang:memory(total)).

%% @doc Gets all entries to transfer (slide) in the given range and starts delta
%%      recording on the DB for changes in this interval.
-spec slide_get_data_start_record(state(), MovingInterval::intervals:interval())
        -> {state(), slide_data()}.
slide_get_data_start_record(State, MovingInterval) ->
    %% all prbr dbs:
    {T1State, MoveRBRData} =
        lists:foldl(
          fun(X, {AccState, AccData}) ->
                  Old = get_prbr_state(State, X),
                  MoveData = db_prbr:get_entries(Old, MovingInterval),
                  New = db_prbr:record_changes(Old, MovingInterval),
                  {set_prbr_state(AccState, X, New), [{X, MoveData} | AccData]}
          end,
          {State, []},
          [kv,
           txid_1, txid_2, txid_3, txid_4,
           leases_1, leases_2, leases_3, leases_4]
         ),

    %% snapshot state and db
    OldDB = get(T1State, db),
    MovingSnapData =
        case db_dht:snapshot_is_running(OldDB) of
            true ->
                {get(T1State, snapshot_state),
                 db_dht:get_snapshot_data(OldDB, MovingInterval)};
            false ->
                {false}
        end,

    %% dht db
    MovingData = db_dht:get_entries(OldDB, MovingInterval),
    NewDB = db_dht:record_changes(OldDB, MovingInterval),
    ?TRACE("~p:slide_get_data_start_record: ~p~nMovingData: ~n~p~nMovingSnapData: ~n~p~nfor
           interval ~p~n~p~n~p",
           [?MODULE, comm:this(), MovingData, MovingSnapData,
            MovingInterval, OldDB, NewDB]),
    NewState = set_db(T1State, NewDB),
    {NewState, {{MovingData, MovingSnapData}, MoveRBRData}}.


%% @doc Adds data from slide_get_data_start_record/2 to the local DB.
-spec slide_add_data(state(),slide_data()) -> state().
slide_add_data(State, {{Data, SnapData}, PRBRData}) ->
    T1DB = db_dht:add_data(get(State, db), Data),
    ?TRACE("~p:slide_add_data: ~p~nMovingData:~n~p~nMovingSnapData:~n~p~nPRBR:~n~p",
           [?MODULE, comm:this(), Data, SnapData, PRBRData]),
    T2State =
        case SnapData of
            {false} ->
                set_db(State, T1DB);
            {SnapState, SnapEntries} ->
                T2DB = db_dht:init_snapshot(T1DB),
                T3DB = db_dht:add_snapshot_data(T2DB, SnapEntries),
                T1State = set_db(State, T3DB),
                set_snapshot_state(T1State, SnapState)
        end,

    %% all prbr dbs
    lists:foldl(
      fun({X, XData}, AccState) ->
              DB = get_prbr_state(AccState, X),
              NewDB = db_prbr:add_data(DB, XData),
              set_prbr_state(AccState, X, NewDB)
      end,
      T2State,
      PRBRData).

%% @doc Gets all DB changes in the given interval, stops recording delta infos
%%      and removes the entries in this range from the DB.
-spec slide_take_delta_stop_record(state(), MovingInterval::intervals:interval())
        -> {state(), slide_delta()}.
slide_take_delta_stop_record(State, MovingInterval) ->
    %% all prbr dbs:
    DeltaRBR =
        lists:foldl(
          fun(X, AccData) ->
                  DB = get_prbr_state(State, X),
                  Delta = db_prbr:get_changes(DB, MovingInterval),
                  [{X, Delta} | AccData]
          end,
          [],
          [kv,
           txid_1, txid_2, txid_3, txid_4,
           leases_1, leases_2, leases_3, leases_4]
         ),

    %% db
    OldDB = get(State, db),
    ChangedData = db_dht:get_changes(OldDB, MovingInterval),

    {T1State, MRDelta} = mr_get_delta_states(State, MovingInterval),

    NewState = slide_stop_record(T1State, MovingInterval, true),
    ?TRACE("~p:slide_take_delta_stop_record: ~p~nChangedData: ~n~p~n~p",
           [?MODULE, comm:this(), ChangedData, get(NewState, db)]),
    {NewState, {ChangedData, DeltaRBR, MRDelta}}.

%% @doc Adds delta infos from slide_take_delta_stop_record/2 to the local DB.
-spec slide_add_delta(state(), slide_delta()) -> state().
slide_add_delta(State, {{ChangedData, DeletedKeys}, PRBRDelta, MRDelta}) ->
    NewDB1 = db_dht:add_data(get(State, db), ChangedData),
    NewDB2 = db_dht:delete_entries(NewDB1, intervals:from_elements(DeletedKeys)),
    ?TRACE("~p:slide_add_delta: ~p~nChangedData: ~n~p~n~p",
           [?MODULE, comm:this(), {ChangedData, DeletedKeys}, NewDB2]),
    T1State = set_db(State, NewDB2),

    T2State = mr_add_delta(T1State, MRDelta),

    %% all prbr dbs
    lists:foldl(
      fun({X, {XData, DelKeys}}, AccState) ->
              DB = get_prbr_state(AccState, X),
              TDB = db_prbr:add_data(DB, XData),
              NewDB = db_prbr:delete_entries(
                        TDB,
                        intervals:from_elements(DelKeys)),
              set_prbr_state(AccState, X, NewDB)
      end,
      T2State,
      PRBRDelta).

%% @doc Stops recording changes in the given interval.
%%      Optionally, the data in this range can be deleted.
-spec slide_stop_record(state(), MovingInterval::intervals:interval(),
                        RemoveDataInInterval::boolean()) -> state().
slide_stop_record(State, MovingInterval, Remove) ->
    %% all prbr dbs:
    T1State =
        lists:foldl(
          fun(X, AccState) ->
                  DB = get_prbr_state(AccState, X),
                  TDB = db_prbr:stop_record_changes(DB, MovingInterval),
                  XDB =
                      if Remove -> db_prbr:delete_entries(TDB, MovingInterval);
                         true   -> TDB
                      end,
                  set_prbr_state(AccState, X, XDB)
          end,
          State,
          [kv,
           txid_1, txid_2, txid_3, txid_4,
           leases_1, leases_2, leases_3, leases_4]
         ),

    NewDB1 = db_dht:stop_record_changes(get(T1State, db), MovingInterval),
    NewDB = if Remove -> db_dht:delete_entries(NewDB1, MovingInterval);
               true   -> NewDB1
            end,
    set_db(T1State, NewDB).

%% @doc Returns a key so that there are no more than TargetLoad entries
%%      between Begin and this key in the DBs.
-spec get_split_key(state(), Begin::?RT:key(), End::?RT:key(),
                    TargetLoad::pos_integer(), Direction::forward | backward)
        -> {?RT:key(), TakenLoad::pos_integer()}.
get_split_key(State, Begin, End, TargetLoad, Direction) ->
    db_dht:get_split_key(get(State, db), Begin, End, TargetLoad, Direction).

-spec mr_get_delta_states(state(), intervals:interval()) -> {state(),
                                                             {orddict:orddict(),
                                                              orddict:orddict()}}.
mr_get_delta_states(State = #state{mr_state = MRStates,
                                   mr_master_state = MasterStates},
                    Interval) ->
    {NewMRStates, MRDelta} = orddict:fold(
     fun(K, MRState, {StateAcc, DeltaAcc}) ->
             {NewState, Delta} = mr_state:get_slide_delta(MRState, Interval),
             {orddict:store(K, NewState, StateAcc),
              orddict:store(K, Delta, DeltaAcc)}
     end,
     {orddict:new(), orddict:new()},
     MRStates),
    ?TRACE_MR_SLIDE("~p fold over master states ~p~n", [self(), MasterStates]),
    {RemainingMasterState, MovingMasterState} =
    orddict:fold(
     fun(K, MasterState, {StateAcc, DeltaAcc}) ->
             case mr_master_state:get_slide_delta(MasterState, Interval) of
                 {true, Delta} ->
                     %% slide
                     {StateAcc,
                      orddict:store(K, Delta, DeltaAcc)};
                 {false, NewState} ->
                     %% no slide
                     {orddict:store(K, NewState, StateAcc),
                      DeltaAcc}
             end
     end,
     {orddict:new(), orddict:new()},
     MasterStates),
    ?TRACE_MR_SLIDE("~p delta mrstates are ~p~ndelta master states are~p~n",
                    [self(), {NewMRStates, MRDelta},
                     {RemainingMasterState,
                      MovingMasterState}]),
    {State#state{mr_state = NewMRStates,
                 mr_master_state = RemainingMasterState},
     {MRDelta, MovingMasterState}}.

-spec mr_add_delta(state(), {orddict:orddict(), orddict:orddict()}) -> state().
mr_add_delta(State = #state{mr_state = MRStates,
                            mr_master_state = MasterStates},
             {MRDeltaStates, MasterDelta}) ->
    ?TRACE_MR_SLIDE("~p adding delta state: ~p~n~p~n", [self(), MRDeltaStates,
                                              MasterDelta]),
    NewMRState = orddict:fold(
     fun(K, MRState, Acc) ->
             New = case orddict:find(K, Acc) of
                 {ok, ExState} ->
                     mr_state:merge_states(ExState, MRState);
                 error ->
                     mr_state:init_slide_state(MRState)
             end,
             orddict:store(K, New, Acc)
     end,
     MRStates,
     MRDeltaStates),
    NewMasterStates =
    orddict:fold(
     fun(K, NewState, Acc) ->
             case mr_master_state:get(outstanding, NewState) of
                 snapshot ->
                     ?TRACE_MR_SLIDE(
                        "master state moved while snapshoting...dispatching again",
                        []),
                     mr_master:dispatch_snapshot(K);
                 false ->
                     %% nothing to do
                     ok
             end,
             orddict:store(K, NewState, Acc)
     end,
     MasterStates,
     MasterDelta),
    ?TRACE_MR_SLIDE("~p delta states added~n~p~n", [self(), NewMRState]),
    State#state{mr_state = NewMRState,
                mr_master_state = NewMasterStates}.
