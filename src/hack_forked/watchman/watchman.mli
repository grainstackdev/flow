(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

module Watchman_process_helpers : sig
  module J = Hh_json_helpers.AdhocJsonHelpers

  val debug : bool

  exception Read_payload_too_long

  val assert_no_error : Hh_json.json -> unit

  val sanitize_watchman_response : debug_logging:bool -> string -> Hh_json.json
end

module Functor (Watchman_process : Watchman_sig.WATCHMAN_PROCESS) :
  Watchman_sig.S with type 'a result = 'a Watchman_process.result
