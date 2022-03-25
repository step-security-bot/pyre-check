(*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

(* Intervals that represent non-strict subclasses of a class. Intervals are based on the DFS start
 * and finish discovery times when traversing the class hierarchy. For example, consider the
 * following classes.
 *
 * ```
 * class A: pass
 * class B(A): pass
 * class C(A): pass
 * class D(B, C): pass
 * ```
 *
 * Then, we may represent D's subclasses with [3,4], represent B's subclasses with [2,5] (which
 * subsumes subclass D's class interval [3,4]), represent C's subclasses with [3,4] and [6,7]
 * (which subsumes subclass D's class interval [3,4] and its own interval [6,7]), and represent A's
 * subclasses with [1,8] (which subsumes the class intervals of subclasses B, C, and D).
 *)
type t

val empty : t

val equal : t -> t -> bool

(* Create a class interval that is representable as a single range. Multiple disjoint ranges can be
   created with the union operation. *)
val create : int -> int -> t

val join : t -> t -> t

val meet : t -> t -> t

val compute_intervals : ClassHierarchyGraph.t -> t ClassHierarchyGraph.ClassNameMap.t

val show : t -> string

val pp : Format.formatter -> t -> unit

val top : t

module SharedMemory : sig
  val add : class_name:ClassHierarchyGraph.class_name -> interval:t -> unit

  val get : class_name:ClassHierarchyGraph.class_name -> t option

  val store : t ClassHierarchyGraph.ClassNameMap.t -> unit
end
