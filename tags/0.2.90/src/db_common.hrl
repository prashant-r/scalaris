% @copyright 2010-2011 Zuse Institute Berlin

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
%% @doc Common functions for database implementations.
%%      Note: include from a DB implementation!
%%      TODO: Most of them are only provided for convenience - check if
%%      they are still needed (they all are based on the new
%%      ?DB:get_entry/2, ?DB:get_entry2/2, ?DB:set_entry/2,
%%      ?DB:update_entry/2 and ?DB:delete_entry/2 functions)
%% @end
%% @version $Id$

%% @doc Closes the given DB and deletes all contents (this DB can thus not be
%%      re-opened using open/1).
close_(State) ->
    close_(State, true).

%% @doc Gets an entry from the DB. If there is no entry with the given key,
%%      an empty entry will be returned.
get_entry_(State, Key) ->
    {_Exists, Result} = get_entry2_(State, Key),
    Result.

%% @doc Reads the version and value of a key.
read(DB, Key) ->
    DBEntry = get_entry_(DB, Key),
    {ok, db_entry:get_value(DBEntry), db_entry:get_version(DBEntry)}.

%% @doc Updates the value of the given key.
write(DB, Key, Value, Version) ->
    {Exists, DBEntry} = get_entry2_(DB, Key),
    case Exists of
        false ->
            NewEntry = db_entry:new(Key, Value, Version),
            set_entry_(DB, NewEntry);
        _ ->
            NewEntry = db_entry:set_value(
                         db_entry:set_version(DBEntry, Version), Value),
            update_entry_(DB, NewEntry)
    end.

%% @doc Deletes the key. Returns {DB, undef} if the key does not exist in the
%%      DB, {DB, locks_set} if read or write locks are still set and {DB, ok}
%%      if the operation was successfully performed.
delete(DB, Key) ->
    {Exists, DBEntry} = get_entry2_(DB, Key),
    case Exists of
        false ->
            {DB, undef};
        _ ->
            case db_entry:get_writelock(DBEntry) =:= false andalso
                     db_entry:get_readlock(DBEntry) =:= 0 of
                true ->
                    {delete_entry_(DB, DBEntry), ok};
                _ ->
                    {DB, locks_set}
            end
    end.

%% @doc Gets (non-empty) db_entry objects in the given range.
get_entries_(State, Interval) ->
    {Elements, RestInterval} = intervals:get_elements(Interval),
    case intervals:is_empty(RestInterval) of
        true -> [E || Key <- Elements,
                      E <- [get_entry_(State, Key)],
                      not db_entry:is_empty(E)];
        _ -> get_entries_(State,
                          fun(DBEntry) ->
                                  (not db_entry:is_empty(DBEntry)) andalso
                                      intervals:in(db_entry:get_key(DBEntry), Interval)
                          end,
                          fun(DBEntry) -> DBEntry end)
    end.

%% @doc Updates all (existing or non-existing) non-locked entries from
%%      NewEntries for which Pred(OldEntry, NewEntry) returns true with
%%      UpdateFun(OldEntry, NewEntry).
update_entries_(OldDB, NewEntries, Pred, UpdateFun) ->
    F = fun(NewEntry, DB) ->
                {Exists, OldEntry} = get_entry2_(DB, db_entry:get_key(NewEntry)),
                IsNotLocked = (not db_entry:get_writelock(OldEntry)) andalso
                                  db_entry:get_readlock(OldEntry) =:= 0,
                IsUpdatable = IsNotLocked andalso Pred(OldEntry, NewEntry),
                case Exists of
                    false when IsUpdatable ->
                        set_entry_(DB, UpdateFun(OldEntry, NewEntry));
                    _ when IsUpdatable ->
                        update_entry_(DB, UpdateFun(OldEntry, NewEntry));
                    _ ->
                        DB
                end
        end,
    lists:foldl(F, OldDB, NewEntries).

%% @doc Checks whether all entries in the DB are valid, i.e.
%%      - no writelocks and readlocks at the same time
%%      - no empty_val values (these should only be in the DB temporarily)
%%      - version is greater than or equal to 0
%%      Returns the result of the check and a list of invalid entries.
check_db(DB) ->
    Data = get_data(DB),
    ValidFun = fun(DBEntry) ->
                       not db_entry:is_empty(DBEntry) andalso
                           not (db_entry:get_writelock(DBEntry) andalso
                                    db_entry:get_readlock(DBEntry) > 0) andalso
                           db_entry:get_version(DBEntry) >= 0
               end,
    {_Valid, Invalid} = lists:partition(ValidFun, Data),
    case Invalid of
        [] -> {true, []};
        _  -> {false, Invalid}
    end.

%% @doc Adds the new interval to the interval to record changes for. Entries
%%      which have (potentially) changed can then be gathered by get_changes/1.
record_changes_({DB, CKInt, CKDB}, NewInterval) ->
    {DB, intervals:union(CKInt, NewInterval), CKDB}.

%% @doc Stops recording changes and removes all entries from the table of
%%      changed keys.
stop_record_changes_({DB, _CKInt, CKDB}) ->
    ?CKETS:delete_all_objects(CKDB),
    {DB, intervals:empty(), CKDB}.

%% @doc Stops recording changes in the given interval and removes all such
%%      entries from the table of changed keys.
stop_record_changes_({DB, CKInt, CKDB}, Interval) ->
    F = fun (DBEntry, _) ->
                 Key = db_entry:get_key(DBEntry),
                 case intervals:in(Key, Interval) of
                     true -> ?CKETS:delete(CKDB, Key);
                     _    -> true
                 end
        end,
    ?CKETS:foldl(F, true, CKDB),
    {DB, intervals:minus(CKInt, Interval), CKDB}.

%% @doc Gets all db_entry objects which have (potentially) been changed or
%%      deleted (might return objects that have not changed but have been
%%      touched by one of the DB setters).
get_changes_({_DB, _CKInt, CKDB} = State) ->
    get_changes_helper(State, ?CKETS:tab2list(CKDB), intervals:all(), [], []).

%% @doc Gets all db_entry objects in the given interval which have
%%      (potentially) been changed or deleted (might return objects that have
%%      not changed but have been touched by one of the DB setters).
get_changes_({_DB, _CKInt, CKDB} = State, Interval) ->
    get_changes_helper(State, ?CKETS:tab2list(CKDB), Interval, [], []).

%% @doc Helper for get_changes/2 that adds the entry of a changed key either to
%%      the list of changed entries or to the list of deleted entries.
-spec get_changes_helper(State::db_t(), ChangedKeys::[{?RT:key()}],
        Interval::intervals:interval(), ChangedEntries::[db_entry:entry()],
        DeletedKeys::[?RT:key()])
            -> {ChangedEntries::[db_entry:entry()], DeletedKeys::[?RT:key()]}.
get_changes_helper(_State, [], _Interval, ChangedEntries, DeletedKeys) ->
    {ChangedEntries, DeletedKeys};
get_changes_helper(State, [{CurKey} | RestKeys], Interval, ChangedEntries, DeletedKeys) ->
    case intervals:in(CurKey, Interval) of
        true ->
            {Existing, Entry} = get_entry2_(State, CurKey),
            case Existing of
                true -> get_changes_helper(State, RestKeys, Interval, [Entry | ChangedEntries], DeletedKeys);
                _    -> get_changes_helper(State, RestKeys, Interval, ChangedEntries, [CurKey | DeletedKeys])
            end;
        _ -> get_changes_helper(State, RestKeys, Interval, ChangedEntries, DeletedKeys)
    end.
