% @copyright 2011 Zuse Institute Berlin

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

%% @author Maik Lange <malange@informatik.hu-berlin.de>
%% @doc    Merkle tree (hash tree) implementation
%%         with configurable bucketing, branching and hashing.
%%         The tree will evenly divide its interval with its subnodes.
%%         If the item count of a leaf node exceeds bucket size the node
%%         will switch to an internal node. The items will be distributed to
%%         its new child nodes which evenly divide the parents interval.
%%         To finish building the structure gen_hashes has to be called to generate
%%         the node signatures.
%% @end
%% @version $Id$

-module(merkle_tree).

-include("record_helpers.hrl").
-include("scalaris.hrl").

-export([new/1, new/3, insert/3, empty/0, is_empty/1,
         set_root_interval/2, size/1, gen_hashes/1,
         get_hash/1]).

-ifdef(with_export_type_support).
-export_type([mt_config/0, merkle_tree/0]).
-endif.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Types
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-type mt_node_key()     :: binary() | nil.
-type mt_interval()     :: intervals:interval(). 
-type mt_bucket()       :: orddict:orddict() | nil.
-type hash_fun()        :: fun((binary()) -> mt_node_key()).
-type inner_hash_fun()  :: fun(([mt_node_key()]) -> mt_node_key()).

-record(mt_config,
        {
         branch_factor  = 2                 :: pos_integer(),   %number of childs per inner node
         bucket_size    = 64                :: pos_integer(),   %max items in a leaf
         leaf_hf        = fun crypto:sha/1  :: hash_fun(),      %hash function for leaf signature creation
         inner_hf       = get_XOR_fun()     :: inner_hash_fun() %hash function for inner node signature creation         
         }).
-type mt_config() :: #mt_config{}.

-type mt_node()         :: {Hash        :: mt_node_key(),       %hash of childs/containing items 
                            Count       :: non_neg_integer(),   %in inner nodes number of subnodes, in leaf nodes bucket size
                            Bucket      :: mt_bucket(),         %item storage
                            Interval    :: mt_interval(),       %represented interval
                            Child_list  :: [mt_node()]}.

-opaque merkle_tree() :: {mt_config(), Root::mt_node()}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Empty
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% @doc Insert on an empty tree fail. First operation on an empty tree should be set_interval.
-spec empty() -> merkle_tree().
empty() ->
    {#mt_config{}, {nil, 0, nil, intervals:empty(), []}}.

-spec is_empty(merkle_tree()) -> boolean().
is_empty({_, {nil, 0, nil, I, []}}) -> intervals:is_empty(I);
is_empty(_) -> false.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% New
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec new(mt_interval()) -> merkle_tree().
new(Interval) ->
    {#mt_config{}, {nil, 0, orddict:new(), Interval, []}}.

-spec new(mt_interval(), mt_config()) -> merkle_tree().
new(Interval, Conf) ->
    {Conf, {nil, 0, orddict:new(), Interval, []}}.

-spec new(mt_interval(), Branch_factor::pos_integer(), Bucket_size::pos_integer()) -> merkle_tree().
new(Interval, BranchFactor, BucketSize) ->
    {#mt_config{ branch_factor = BranchFactor, bucket_size = BucketSize }, 
     {nil, 0, orddict:new(), Interval, []}}.
    
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Get hash
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec get_hash(merkle_tree() | mt_node()) -> mt_node_key().
get_hash({_, Node}) -> get_hash(Node);
get_hash({Hash, _, _, _, _}) -> Hash.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% set_root_interval
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% @doc Returns an empty merkle tree ready for work.
-spec set_root_interval(mt_interval(), merkle_tree()) -> merkle_tree().
set_root_interval(I, {Conf, _}) ->
    new(I, Conf).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Insert
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec insert(Key::term(), Val::term(), merkle_tree()) -> merkle_tree().
insert(Key, Val, {Config, Root}) ->
    Changed = insert_to_node(Key, Val, Root, Config),
    {Config, Changed}.


-spec insert_to_node(Key::term(), Val::term(), mt_node(), mt_config()) -> mt_node().

insert_to_node(Key, Val, {Hash, Count, Bucket, Interval, []}, Config) 
  when Count >= 0 andalso Count < Config#mt_config.bucket_size ->
    {Hash, Count + 1, orddict:store(Key, Val, Bucket), Interval, []};

insert_to_node(Key, Val, {_, Count, Bucket, Interval, []}, Config) 
  when Count =:= Config#mt_config.bucket_size ->
    ChildI = intervals:split(Interval, Config#mt_config.branch_factor),
    NewLeafs = lists:map(fun(I) -> 
                              NewBucket = orddict:filter(fun(K, _) -> intervals:in(K, I) end, Bucket),
                              {nil, orddict:size(NewBucket), NewBucket, I, []}
                         end, ChildI), 
    insert_to_node(Key, Val, {nil, 1 + Config#mt_config.branch_factor, nil, Interval, NewLeafs}, Config);

insert_to_node(Key, Val, {Hash, Count, nil, Interval, Childs}, Config) ->    
    {[Dest], Rest} = lists:partition(fun({_, _, _, I, _}) -> intervals:in(Key, I) end, Childs),
    OldSize = size_node(Dest),
    NewDest = insert_to_node(Key, Val, Dest, Config),
    {Hash, Count + (size_node(NewDest) - OldSize), nil, Interval, [NewDest|Rest]}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Generate Signatures/Hashes
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec gen_hashes(merkle_tree()) -> merkle_tree().
gen_hashes({Config, Root}) ->
    {Config, gen_hash(Root, Config)}.

gen_hash({_, Count, Bucket, I, []}, Config) ->
    LeafHf = Config#mt_config.leaf_hf,
    Hash = case Count > 0 of
               true -> LeafHf(erlang:term_to_binary(orddict:fetch_keys(Bucket)));
               _    -> LeafHf(term_to_binary(0))
           end,
    {Hash, Count, Bucket, I, []};
gen_hash({_, Count, nil, I, List}, Config) ->    
    NewChilds = lists:map(fun(X) -> gen_hash(X, Config) end, List),
    InnerHf = Config#mt_config.inner_hf,
    Hash = InnerHf(lists:map(fun({H, _, _, _, _}) -> H end, NewChilds)),
    {Hash, Count, nil, I, NewChilds}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Size
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
-spec size(merkle_tree()) -> non_neg_integer().
size({_, Root}) ->
    size_node(Root).

-spec size_node(mt_node()) -> non_neg_integer().
size_node({_, _, _, _, []}) ->
    1;
size_node({_, C, _, _, _}) ->
    C.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Local Functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
get_XOR_fun() ->
    (fun([H|T]) -> lists:foldl(fun(X, Acc) -> binary_xor(X, Acc) end, H, T) end).

-spec binary_xor(binary(), binary()) -> binary().
binary_xor(A, B) ->
    Size = bit_size(A),
    <<X:Size>> = A,
    <<Y:Size>> = B,
    <<(X bxor Y):Size>>.
