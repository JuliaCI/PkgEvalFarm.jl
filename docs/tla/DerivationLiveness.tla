---------------------------- MODULE DerivationLiveness ----------------------------
(***************************************************************************)
(* The derivation half of the sealing cache protocol (docs/sealing.md),    *)
(* modeled for one derivation context (one cache key).                     *)
(*                                                                         *)
(* Ground truth is the DynamoDB job item; SQS messages are hints. The      *)
(* claim path makes duplicate messages harmless (conditional               *)
(* pending/running -> running; strays for finished jobs are deleted), so   *)
(* re-sending a message is always SAFE. This module is about whether it is *)
(* ever NECESSARY: any party may die between creating the item and sending *)
(* its message (modeled inside Ingest), and SQS may drop a claimed         *)
(* message's redelivery to the dead-letter queue (CrashDrop). Loss is      *)
(* therefore unavoidable; the protocol's liveness must come from healing.  *)
(*                                                                         *)
(* With Healing = FALSE (the protocol as first shipped: an existing        *)
(* pending/running item is "already handled", nobody re-sends), TLC finds  *)
(* the zombie: a lost message strands the item non-terminal forever and    *)
(* every holder of that context blocks until its job is killed — exactly   *)
(* what run gh-5241627143 hit (473 pending derivations with attempts=0     *)
(* and no message; 2,462 consumer jobs killed at their time limits).       *)
(*                                                                         *)
(* With Healing = TRUE (rearm_derivation!: holders and fresh wants CAS the *)
(* enqueued_at lease and re-send when the item shows no sign of life),     *)
(* every hold releases, under fairness assumptions that say only: time     *)
(* passes (leases expire), sends/claims that stay possible eventually      *)
(* happen, and infinitely many derivation attempts do not all crash.       *)
(*                                                                         *)
(* Abstractions: one context; one worker slot (extra workers add duplicate *)
(* work, not new item-state behaviors — publication is create-only in S3); *)
(* the pending-claim window and the running-staleness window both collapse *)
(* into the single lease bit (their difference is quantitative, not        *)
(* structural); "done" is any terminal status — sealed publishes the       *)
(* artifact, unsealable/error do not, and either releases holders (a 404   *)
(* makes the requester compile locally, which is then correct).            *)
(*                                                                         *)
(* Model-check (from this directory):                                      *)
(*   java -cp tla2tools.jar tlc2.TLC -config Broken.cfg DerivationLiveness *)
(*     => Temporal properties were violated (the zombie trace)             *)
(*   java -cp tla2tools.jar tlc2.TLC -config Healed.cfg DerivationLiveness *)
(*     => no violations                                                    *)
(***************************************************************************)
EXTENDS Naturals

CONSTANTS Requesters,   \* consumer jobs that may come to want this context
          MaxMsgs,      \* bound on simultaneously outstanding messages
          Healing       \* FALSE = shipped protocol, TRUE = with rearm_derivation!

VARIABLES item,       \* the job item: "none" | "pending" | "running" | "done"
          msgs,       \* live (deliverable) SQS messages for this context
          busy,       \* a worker is processing a claimed message
          published,  \* the artifact reached the store
          lease,      \* enqueued_at is fresh (within the re-arm window)
          pc          \* requester state: "idle" | "holding" | "released"

vars == <<item, msgs, busy, published, lease, pc>>

TypeOK ==
    /\ item \in {"none", "pending", "running", "done"}
    /\ msgs \in 0..MaxMsgs
    /\ busy \in BOOLEAN
    /\ published \in BOOLEAN
    /\ lease \in BOOLEAN
    /\ pc \in [Requesters -> {"idle", "holding", "released"}]

Init ==
    /\ item = "none"
    /\ msgs = 0
    /\ busy = FALSE
    /\ published = FALSE
    /\ lease = FALSE
    /\ pc = [r \in Requesters |-> "idle"]

(***************************************************************************)
(* A requester's ensure misses and creates the derivation: the item is     *)
(* written (stamping the enqueued_at lease), then the message is sent —    *)
(* unless the ingester dies in between (second disjunct). The requester    *)
(* holds either way: other requesters of the same context survive even     *)
(* when the ingesting worker died, and the item is now theirs to wait on.  *)
(* Note the crash disjunct exists in BOTH protocol variants: the fix does  *)
(* not (cannot) prevent the loss, it heals it.                             *)
(***************************************************************************)
Ingest(r) ==
    /\ pc[r] = "idle"
    /\ item = "none"
    /\ item' = "pending"
    /\ lease' = TRUE
    /\ \/ msgs' = msgs + 1     \* message sent
       \/ msgs' = msgs         \* died between item creation and send
    /\ pc' = [pc EXCEPT ![r] = "holding"]
    /\ UNCHANGED <<busy, published>>

\* a later requester's ensure finds the item non-terminal and joins the hold
Join(r) ==
    /\ pc[r] = "idle"
    /\ item \in {"pending", "running"}
    /\ ~published
    /\ pc' = [pc EXCEPT ![r] = "holding"]
    /\ UNCHANGED <<item, msgs, busy, published, lease>>

\* time passes: the enqueued_at stamp ages beyond the re-arm window
LeaseExpire ==
    /\ lease
    /\ lease' = FALSE
    /\ UNCHANGED <<item, msgs, busy, published, pc>>

(***************************************************************************)
(* The fix (rearm_derivation!): whoever waits, heals. A holder that       *)
(* observes a non-terminal item past its lease re-sends the message,       *)
(* CAS-renewing the lease so one healer is elected per window. The healer  *)
(* itself may die between its CAS and its send (RearmCrash): that costs    *)
(* one lease window — the lease expires and the next healer retries —      *)
(* never liveness. RearmCrash is deliberately unfair (crashes need not     *)
(* ever stop), while RearmSend gets strong fairness: it is enabled         *)
(* infinitely often (each time a lease expires), and assuming it fires     *)
(* eventually is exactly "healers do not ALL die forever".                 *)
(***************************************************************************)
RearmEnabled ==
    /\ Healing
    /\ \E r \in Requesters : pc[r] = "holding"
    /\ item \in {"pending", "running"}
    /\ ~lease
    /\ msgs < MaxMsgs

RearmSend ==
    /\ RearmEnabled
    /\ msgs' = msgs + 1
    /\ lease' = TRUE
    /\ UNCHANGED <<item, busy, published, pc>>

RearmCrash ==
    /\ RearmEnabled
    /\ msgs' = msgs
    /\ lease' = TRUE
    /\ UNCHANGED <<item, busy, published, pc>>

\* a worker receives a message and wins the conditional status flip
Claim ==
    /\ msgs > 0
    /\ ~busy
    /\ item \in {"pending", "running"}
    /\ item' = "running"
    /\ msgs' = msgs - 1
    /\ busy' = TRUE
    /\ UNCHANGED <<published, lease, pc>>

\* a stray duplicate for a finished job is deleted at claim time
ClaimStray ==
    /\ msgs > 0
    /\ item = "done"
    /\ msgs' = msgs - 1
    /\ UNCHANGED <<item, busy, published, lease, pc>>

\* the derivation terminates: sealed (artifact published) or terminally
\* failed (unsealable/error) — both release holders through the status check
Complete ==
    /\ busy
    /\ item' = "done"
    /\ busy' = FALSE
    /\ \/ published' = TRUE
       \/ published' = published
    /\ UNCHANGED <<msgs, lease, pc>>

\* the worker dies; SQS redelivers after the visibility timeout
CrashRedeliver ==
    /\ busy
    /\ msgs < MaxMsgs
    /\ busy' = FALSE
    /\ msgs' = msgs + 1
    /\ UNCHANGED <<item, published, lease, pc>>

\* the worker dies AND the message is lost (dead-lettered after
\* maxReceiveCount, or retention expired): the item stays "running" forever
\* unless someone re-arms it
CrashDrop ==
    /\ busy
    /\ busy' = FALSE
    /\ UNCHANGED <<item, msgs, published, lease, pc>>

\* the hold releases: artifact available, or terminal status => local compile
Release(r) ==
    /\ pc[r] = "holding"
    /\ published \/ item = "done"
    /\ pc' = [pc EXCEPT ![r] = "released"]
    /\ UNCHANGED <<item, msgs, busy, published, lease>>

Next ==
    \/ \E r \in Requesters : Ingest(r) \/ Join(r) \/ Release(r)
    \/ LeaseExpire \/ RearmSend \/ RearmCrash \/ Claim \/ ClaimStray
    \/ Complete \/ CrashRedeliver \/ CrashDrop

(***************************************************************************)
(* Fairness: crashes are deliberately UNFAIR (they may or may not happen,  *)
(* in any pattern). We assume only that (a) time passes, so leases expire; *)
(* (b) a claim or release that stays possible eventually happens; (c)      *)
(* attempts do not ALL crash forever: RearmSend and Complete get strong    *)
(* fairness — each is enabled infinitely often along any stuck trace, and  *)
(* assuming it eventually fires is exactly "not every healer/worker dies". *)
(***************************************************************************)
Fairness ==
    /\ WF_vars(LeaseExpire)
    /\ SF_vars(RearmSend)
    /\ WF_vars(Claim)
    /\ WF_vars(ClaimStray)
    /\ SF_vars(Complete)
    /\ \A r \in Requesters : WF_vars(Release(r))

Spec == Init /\ [][Next]_vars /\ Fairness

\* safety: a release is always justified, and the artifact only exists once
\* its derivation is terminal
ReleasedJustified ==
    \A r \in Requesters : pc[r] = "released" => (published \/ item = "done")
PublishedMeansDone == published => item = "done"

\* THE property: every hold eventually releases (no consumer job ever
\* blocks until its time-limit kill)
HoldsRelease ==
    \A r \in Requesters : (pc[r] = "holding") ~> (pc[r] = "released")

===================================================================================
