%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92-*-
%% ex: ts=4 sw=4 et
%% @author Seth Falcon <seth@opscode.com>
%% @author Christopher Maier <cm@opscode.com>
%% @copyright 2012 Opscode, Inc.

-module(chef_wm_named_data_item).

-include("chef_wm.hrl").

-mixin([{chef_wm_base, [content_types_accepted/2,
                        content_types_provided/2,
                        finish_request/2,
                        malformed_request/2,
                        ping/2,
                        post_is_create/2]}]).

-mixin([{?BASE_RESOURCE, [forbidden/2,
                          is_authorized/2,
                          service_available/2]}]).


%% chef_wm behaviour callbacks
-behaviour(chef_wm).
-export([
         auth_info/2,
         init/1,
         malformed_request_message/3,
         request_type/0,
         validate_request/3
        ]).

-export([
         allowed_methods/2,
         delete_resource/2,
         from_json/2,
         resource_exists/2,
         to_json/2
       ]).

init(Config) ->
    chef_wm_base:init(?MODULE, Config).

request_type() ->
  "data".

allowed_methods(Req, State) ->
    {['GET', 'PUT', 'DELETE'], Req, State}.

validate_request('GET', Req, State) ->
    {Req, State#base_state{resource_state = #data_state{}}};
validate_request('DELETE', Req, State) ->
    {Req, State#base_state{resource_state = #data_state{}}};
validate_request('PUT', Req, State) ->
    %% FIXME: should we also fetch the data_bag here to make sure that it exists and ensure
    %% we have authz? With the current setup, we will deny malformed requests with 400 even
    %% for a missing or no-perms data_bag.
    Name = chef_rest_util:object_name(data_bag_item, Req),
    Body = wrq:req_body(Req),
    {ok, Item} = chef_data_bag_item:parse_binary_json(Body, {update, Name}),
    DataState = #data_state{data_bag_item_ejson = Item},
    {Req, State#base_state{resource_state = DataState}}.

auth_info(Req, State) ->
  {{create_in_container, data}, Req, State}.

%% If we get here, we know that the data_bag exists and we have authz, here we'll check that
%% the item exists. If items grow their own authz, this logic will move into an enhanced
%% forbidden function.
resource_exists(Req, #base_state{chef_db_context = DbContext,
                                 organization_name = OrgName,
                                 resource_state = DataBagState} = State) ->
    DataBagName = DataBagState#data_state.data_bag_name,
    ItemName = chef_rest_util:object_name(data_bag_item, Req),
    case chef_db:fetch_data_bag_item(DbContext, OrgName, DataBagName, ItemName) of
        not_found ->
            Message = custom_404_msg(Req, DataBagName, ItemName),
            Req1 = chef_rest_util:set_json_body(Req, Message),
            %% WARNING: Webmachine will not halt here if this is a PUT request and we return
            %% {false, Req1, State}; So we force the halt since we do not want PUT only for
            %% update. We don't have this problem for simple objects, such as nodes, because
            %% the 404 is halted explicitly in forbidden.
            {{halt, 404}, Req1, State};
        #chef_data_bag_item{} = Item ->
            DataBagState1 = DataBagState#data_state{chef_data_bag_item = Item},
            State1 = State#base_state{resource_state = DataBagState1},
            {true, Req, State1}
    end.

from_json(Req, #base_state{resource_state = #data_state{
                             data_bag_name = BagName,
                             chef_data_bag_item = Item,
                             data_bag_item_ejson = ItemData}} = State) ->
    %% We have to hack the shared update function so we can post-process and add the cruft
    %% fields for back-compatibility.
    case chef_rest_wm:update_from_json(Req, State, Item, ItemData) of
        {true, Req1, State1} ->
            case darklaunch:is_enabled(<<"add_type_and_bag_to_items">>) of
                true ->
                    CruftItemData = chef_data_bag_item:add_type_and_bag(BagName,
                                                                        ItemData),
                    {true, chef_rest_util:set_json_body(Req1, CruftItemData), State1};
                false ->
                    {true, Req1, State1}
            end;
        {_, _, _} = Else ->
            Else
    end.

to_json(Req, #base_state{resource_state = DataBagState} = State) ->
    Item = DataBagState#data_state.chef_data_bag_item,
    JSON = Item#chef_data_bag_item.serialized_object,
    {chef_db_compression:decompress(JSON), Req, State}.

delete_resource(Req, #base_state{chef_db_context = DbContext,
                                 resource_state = #data_state{
                                     data_bag_name = BagName,
                                     data_bag_item_name = ItemName,
                                     chef_data_bag_item = Item},
                                 requestor = #chef_requestor{
                                     authz_id = RequestorId}}=State) ->

    ok = chef_object_db:delete(DbContext, Item, RequestorId),
    Json = chef_db_compression:decompress(Item#chef_data_bag_item.serialized_object),
    EjsonItem = ejson:decode(Json),
    WrappedItem = chef_data_bag_item:wrap_item(BagName, ItemName, EjsonItem),
    {true, chef_rest_util:set_json_body(Req, WrappedItem), State}.

%% Private utility functions
malformed_request_message(Any, _Req, _State) ->
    error({unexpected_malformed_request_message, Any}).

%% The Ruby API returns a different 404 message just for POSTs
custom_404_msg(Req, BagName, ItemName) ->
    case wrq:method(Req) of
        Update when Update =:= 'POST' ->
            chef_rest_util:not_found_message(data_bag_missing_for_item_post, BagName);
        'PUT' ->
            chef_rest_util:not_found_message(data_bag_item2, {BagName, ItemName});
        'GET' ->
            chef_rest_util:not_found_message(data_bag_item2, {BagName, ItemName});
        'DELETE' ->
            chef_rest_util:not_found_message(data_bag_item1, {BagName, ItemName})
    end.