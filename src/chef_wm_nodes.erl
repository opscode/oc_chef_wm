%% -*- erlang-indent-level: 4;indent-tabs-mode: nil; fill-column: 92 -*-
%% ex: ts=4 sw=4 et
%% @author Seth Falcon <seth@opscode.com>
%% @copyright 2011-2012 Opscode, Inc.

%% @doc Resource module for Chef nodes endpoint
%%
%% The REST API provided by this module is as follows:
%%
%% Create a new node with body of POST being node JSON
%% POST /organizations/:org_name/nodes/
%%
%% Fetch all node names
%% GET /organizations/:org_name/nodes/
%%
%%
-module(chef_wm_nodes).

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

%% I think we will end up moving the generic complete wm callbacks like post_is_create,
%% content_types_* into chef_wm_base and mixing those in here separately so that we only
%% have to have those defined in one place.

%% chef_wm behavior callbacks
-behaviour(chef_wm).
-export([auth_info/2,
         init/1,
         malformed_request_message/3,
         request_type/0,
         validate_request/3]).

-export([allowed_methods/2,
         create_path/2,
         from_json/2,
         resource_exists/2,
         to_json/2]).

init(Config) ->
    chef_wm_base:init(?MODULE, Config).

request_type() ->
    "nodes".

allowed_methods(Req, #base_state{resource_state = NodeState} = State) ->
    {Methods, EnvName} = case wrq:path_info(environment_name, Req) of
                             undefined -> {['GET', 'POST'], undefined};
                             Name -> {['GET'], list_to_binary(Name)}
                         end,
    NodeState1 = NodeState#node_state{environment_name = EnvName},
    {Methods, Req, State#base_state{resource_state = NodeState1}}.

validate_request('GET', Req, State) ->
    {Req, State#base_state{resource_state = #node_state{}}};
validate_request('POST', Req, State) ->
    Body = wrq:req_body(Req),
    {ok, Json} = chef_node:parse_check_binary_as_json_node(Body, create),
    {Req, State#base_state{resource_state = #node_state{node_data = Json}}}.

auth_info(Req, State) ->
    {{create_in_container, node}, Req, State}.

%% @doc If the org exists, then resource exists for POST, GET
%%
%% But org existence check is handled in chef_wm do_malformed_request.
resource_exists(Req, #base_state{chef_db_context = DbContext,
                                 organization_guid = OrgId,
                                 resource_state = NodeState}=State) ->
    %% If we are listing nodes for an environment, check that the environment exists first.
    case NodeState#node_state.environment_name of
        undefined ->
            {true, Req, State};
        EnvName ->
            case chef_db:environment_exists(DbContext, OrgId, EnvName) of
                true -> {true, Req, State};
                false ->
                    Msg = ejson:encode(chef_wm_util:environment_not_found_message(EnvName)),
                    {false, wrq:set_resp_body(Msg, Req),
                     State#base_state{log_msg={env_not_found, EnvName}}}
            end
    end.

to_json(Req, #base_state{resource_state = NodeState}= State) ->
    list_nodes(NodeState#node_state.environment_name, Req, State).

create_path(Req, #base_state{resource_state = NodeState}=State) ->
    #node_state{node_data = NodeJson} = NodeState,
    Name = ej:get({<<"name">>}, NodeJson),
    {binary_to_list(Name), Req, State}.

from_json(Req, #base_state{resource_state = NodeState} = State) ->
    #node_state{node_data = NodeJson, node_authz_id = AuthzId} = NodeState,
    chef_wm_base:create_from_json(Req, State, chef_node, {authz_id, AuthzId}, NodeJson).

%% internal functions
list_nodes(undefined, Req, #base_state{chef_db_context = DbContext,
                                       organization_name = OrgName}=State) ->
    NodeNames = chef_db:fetch_nodes(DbContext, OrgName),
    package_node_list(NodeNames, Req, State);
list_nodes(EnvName, Req, #base_state{chef_db_context = DbContext,
                                     organization_name = OrgName}=State) ->
    NodeNames = chef_db:fetch_nodes(DbContext, OrgName, EnvName),
    package_node_list(NodeNames, Req, State).

package_node_list(NodeNames, Req, #base_state{organization_name = OrgName}=State) ->
    UrlPrefix = node_url_prefix(Req, OrgName),
    NameMap = [ {Name, iolist_to_binary([UrlPrefix, Name])} || Name <- NodeNames ],
    Json = ejson:encode({NameMap}),
    {Json, Req, State#base_state{log_msg = {list, length(NodeNames)}}}.

node_url_prefix(Req, OrgName) ->
    iolist_to_binary([chef_wm_util:base_uri(Req),
                      "/organizations/", OrgName, "/nodes/"]).

%% error message functions

malformed_request_message(Any, _Req, _State) ->
    error({unexpected_malformed_request_message, Any}).