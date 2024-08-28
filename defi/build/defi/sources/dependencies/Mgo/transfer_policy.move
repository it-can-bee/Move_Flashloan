// Copyright (c) MangoNet Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Defines the `TransferPolicy` type and the logic to approve `TransferRequest`s.
///
/// - TransferPolicy - is a highly customizable primitive, which provides an
/// interface for the type owner to set custom transfer rules for every
/// deal performed in the `Kiosk` or a similar system that integrates with TP.
///
/// - Once a `TransferPolicy<T>` is created for and shared (or frozen), the
/// type `T` becomes tradable in `Kiosk`s. On every purchase operation, a
/// `TransferRequest` is created and needs to be confirmed by the `TransferPolicy`
/// hot potato or transaction will fail.
///
/// - Type owner (creator) can set any Rules as long as the ecosystem supports
/// them. All of the Rules need to be resolved within a single transaction (eg
/// pay royalty and pay fixed commission). Once required actions are performed,
/// the `TransferRequest` can be "confimed" via `confirm_request` call.
///
/// - `TransferPolicy` aims to be the main interface for creators to control trades
/// of their types and collect profits if a fee is required on sales. Custom
/// policies can be removed at any moment, and the change will affect all instances
/// of the type at once.
module mgo::transfer_policy {
    use std::vector;
    use std::option::{Self, Option};
    use std::type_name::{Self, TypeName};
    use mgo::package::{Self, Publisher};
    use mgo::tx_context::{sender, TxContext};
    use mgo::object::{Self, ID, UID};
    use mgo::vec_set::{Self, VecSet};
    use mgo::dynamic_field as df;
    use mgo::balance::{Self, Balance};
    use mgo::mgo::MGO;
    use mgo::coin::{Self, Coin};
    use mgo::event;

    /// The number of receipts does not match the `TransferPolicy` requirement.
    const EPolicyNotSatisfied: u64 = 0;
    /// A completed rule is not set in the `TransferPolicy`.
    const EIllegalRule: u64 = 1;
    /// A Rule is not set.
    const EUnknownRequrement: u64 = 2;
    /// Attempting to create a Rule that is already set.
    const ERuleAlreadySet: u64 = 3;
    /// Trying to `withdraw` or `close_and_withdraw` with a wrong Cap.
    const ENotOwner: u64 = 4;
    /// Trying to `withdraw` more than there is.
    const ENotEnough: u64 = 5;

    /// A "Hot Potato" forcing the buyer to get a transfer permission
    /// from the item type (`T`) owner on purchase attempt.
    struct TransferRequest<phantom T> {
        /// The ID of the transferred item. Although the `T` has no
        /// constraints, the main use case for this module is to work
        /// with Objects.
        item: ID,
        /// Amount of MGO paid for the item. Can be used to
        /// calculate the fee / transfer policy enforcement.
        paid: u64,
        /// The ID of the Kiosk / Safe the object is being sold from.
        /// Can be used by the TransferPolicy implementors.
        from: ID,
        /// Collected Receipts. Used to verify that all of the rules
        /// were followed and `TransferRequest` can be confirmed.
        receipts: VecSet<TypeName>
    }

    /// A unique capability that allows the owner of the `T` to authorize
    /// transfers. Can only be created with the `Publisher` object. Although
    /// there's no limitation to how many policies can be created, for most
    /// of the cases there's no need to create more than one since any of the
    /// policies can be used to confirm the `TransferRequest`.
    struct TransferPolicy<phantom T> has key, store {
        id: UID,
        /// The Balance of the `TransferPolicy` which collects `MGO`.
        /// By default, transfer policy does not collect anything , and it's
        /// a matter of an implementation of a specific rule - whether to add
        /// to balance and how much.
        balance: Balance<MGO>,
        /// Set of types of attached rules - used to verify `receipts` when
        /// a `TransferRequest` is received in `confirm_request` function.
        ///
        /// Additionally provides a way to look up currently attached Rules.
        rules: VecSet<TypeName>
    }

    /// A Capability granting the owner permission to add/remove rules as well
    /// as to `withdraw` and `destroy_and_withdraw` the `TransferPolicy`.
    struct TransferPolicyCap<phantom T> has key, store {
        id: UID,
        policy_id: ID
    }

    /// Event that is emitted when a publisher creates a new `TransferPolicyCap`
    /// making the discoverability and tracking the supported types easier.
    struct TransferPolicyCreated<phantom T> has copy, drop { id: ID }

    /// Event that is emitted when a publisher destroys a `TransferPolicyCap`.
    /// Allows for tracking supported policies.
    struct TransferPolicyDestroyed<phantom T> has copy, drop { id: ID }

    /// Key to store "Rule" configuration for a specific `TransferPolicy`.
    struct RuleKey<phantom T: drop> has copy, store, drop {}

    /// Construct a new `TransferRequest` hot potato which requires an
    /// approving action from the creator to be destroyed / resolved. Once
    /// created, it must be confirmed in the `confirm_request` call otherwise
    /// the transaction will fail.
    public fun new_request<T>(
        item: ID, paid: u64, from: ID
    ): TransferRequest<T> {
        TransferRequest { item, paid, from, receipts: vec_set::empty() }
    }

    /// Register a type in the Kiosk system and receive a `TransferPolicy` and
    /// a `TransferPolicyCap` for the type. The `TransferPolicy` is required to
    /// confirm kiosk deals for the `T`. If there's no `TransferPolicy`
    /// available for use, the type can not be traded in kiosks.
    public fun new<T>(
        pub: &Publisher, ctx: &mut TxContext
    ): (TransferPolicy<T>, TransferPolicyCap<T>) {
        assert!(package::from_package<T>(pub), 0);
        let id = object::new(ctx);
        let policy_id = object::uid_to_inner(&id);

        event::emit(TransferPolicyCreated<T> { id: policy_id });

        (
            TransferPolicy { id, rules: vec_set::empty(), balance: balance::zero() },
            TransferPolicyCap { id: object::new(ctx), policy_id }
        )
    }

    #[allow(lint(self_transfer, share_owned))]
    /// Initialize the Tranfer Policy in the default scenario: Create and share
    /// the `TransferPolicy`, transfer `TransferPolicyCap` to the transaction
    /// sender.
    entry fun default<T>(pub: &Publisher, ctx: &mut TxContext) {
        let (policy, cap) = new<T>(pub, ctx);
        mgo::transfer::share_object(policy);
        mgo::transfer::transfer(cap, sender(ctx));
    }

    /// Withdraw some amount of profits from the `TransferPolicy`. If amount
    /// is not specified, all profits are withdrawn.
    public fun withdraw<T>(
        self: &mut TransferPolicy<T>,
        cap: &TransferPolicyCap<T>,
        amount: Option<u64>,
        ctx: &mut TxContext
    ): Coin<MGO> {
        assert!(object::id(self) == cap.policy_id, ENotOwner);

        let amount = if (option::is_some(&amount)) {
            let amt = option::destroy_some(amount);
            assert!(amt <= balance::value(&self.balance), ENotEnough);
            amt
        } else {
            balance::value(&self.balance)
        };

        coin::take(&mut self.balance, amount, ctx)
    }

    /// Destroy a TransferPolicyCap.
    /// Can be performed by any party as long as they own it.
    public fun destroy_and_withdraw<T>(
        self: TransferPolicy<T>, cap: TransferPolicyCap<T>, ctx: &mut TxContext
    ): Coin<MGO> {
        assert!(object::id(&self) == cap.policy_id, ENotOwner);

        let TransferPolicyCap { id: cap_id, policy_id } = cap;
        let TransferPolicy { id, rules: _, balance } = self;

        object::delete(id);
        object::delete(cap_id);
        event::emit(TransferPolicyDestroyed<T> { id: policy_id });
        coin::from_balance(balance, ctx)
    }

    /// Allow a `TransferRequest` for the type `T`. The call is protected
    /// by the type constraint, as only the publisher of the `T` can get
    /// `TransferPolicy<T>`.
    ///
    /// Note: unless there's a policy for `T` to allow transfers,
    /// Kiosk trades will not be possible.
    public fun confirm_request<T>(
        self: &TransferPolicy<T>, request: TransferRequest<T>
    ): (ID, u64, ID) {
        let TransferRequest { item, paid, from, receipts } = request;
        let completed = vec_set::into_keys(receipts);
        let total = vector::length(&completed);

        assert!(total == vec_set::size(&self.rules), EPolicyNotSatisfied);

        while (total > 0) {
            let rule_type = vector::pop_back(&mut completed);
            assert!(vec_set::contains(&self.rules, &rule_type), EIllegalRule);
            total = total - 1;
        };

        (item, paid, from)
    }

    // === Rules Logic ===

    /// Add a custom Rule to the `TransferPolicy`. Once set, `TransferRequest` must
    /// receive a confirmation of the rule executed so the hot potato can be unpacked.
    ///
    /// - T: the type to which TransferPolicy<T> is applied.
    /// - Rule: the witness type for the Custom rule
    /// - Config: a custom configuration for the rule
    ///
    /// Config requires `drop` to allow creators to remove any policy at any moment,
    /// even if graceful unpacking has not been implemented in a "rule module".
    public fun add_rule<T, Rule: drop, Config: store + drop>(
        _: Rule, policy: &mut TransferPolicy<T>, cap: &TransferPolicyCap<T>, cfg: Config
    ) {
        assert!(object::id(policy) == cap.policy_id, ENotOwner);
        assert!(!has_rule<T, Rule>(policy), ERuleAlreadySet);
        df::add(&mut policy.id, RuleKey<Rule> {}, cfg);
        vec_set::insert(&mut policy.rules, type_name::get<Rule>())
    }

    /// Get the custom Config for the Rule (can be only one per "Rule" type).
    public fun get_rule<T, Rule: drop, Config: store + drop>(
        _: Rule, policy: &TransferPolicy<T>)
    : &Config {
        df::borrow(&policy.id, RuleKey<Rule> {})
    }

    /// Add some `MGO` to the balance of a `TransferPolicy`.
    public fun add_to_balance<T, Rule: drop>(
        _: Rule, policy: &mut TransferPolicy<T>, coin: Coin<MGO>
    ) {
        assert!(has_rule<T, Rule>(policy), EUnknownRequrement);
        coin::put(&mut policy.balance, coin)
    }

    /// Adds a `Receipt` to the `TransferRequest`, unblocking the request and
    /// confirming that the policy requirements are satisfied.
    public fun add_receipt<T, Rule: drop>(
        _: Rule, request: &mut TransferRequest<T>
    ) {
        vec_set::insert(&mut request.receipts, type_name::get<Rule>())
    }

    /// Check whether a custom rule has been added to the `TransferPolicy`.
    public fun has_rule<T, Rule: drop>(policy: &TransferPolicy<T>): bool {
        df::exists_(&policy.id, RuleKey<Rule> {})
    }

    /// Remove the Rule from the `TransferPolicy`.
    public fun remove_rule<T, Rule: drop, Config: store + drop>(
        policy: &mut TransferPolicy<T>, cap: &TransferPolicyCap<T>
    ) {
        assert!(object::id(policy) == cap.policy_id, ENotOwner);
        let _: Config = df::remove(&mut policy.id, RuleKey<Rule> {});
        vec_set::remove(&mut policy.rules, &type_name::get<Rule>());
    }

    // === Fields access: TransferPolicy ===

    /// Allows reading custom attachments to the `TransferPolicy` if there are any.
    public fun uid<T>(self: &TransferPolicy<T>): &UID { &self.id }

    /// Get a mutable reference to the `self.id` to enable custom attachments
    /// to the `TransferPolicy`.
    public fun uid_mut_as_owner<T>(
        self: &mut TransferPolicy<T>, cap: &TransferPolicyCap<T>,
    ): &mut UID {
        assert!(object::id(self) == cap.policy_id, ENotOwner);
        &mut self.id
    }

    /// Read the `rules` field from the `TransferPolicy`.
    public fun rules<T>(self: &TransferPolicy<T>): &VecSet<TypeName> {
        &self.rules
    }

    // === Fields access: TransferRequest ===

    /// Get the `item` field of the `TransferRequest`.
    public fun item<T>(self: &TransferRequest<T>): ID { self.item }

    /// Get the `paid` field of the `TransferRequest`.
    public fun paid<T>(self: &TransferRequest<T>): u64 { self.paid }

    /// Get the `from` field of the `TransferRequest`.
    public fun from<T>(self: &TransferRequest<T>): ID { self.from }

    // === Tests ===

    #[test_only]
    /// Create a new TransferPolicy for testing purposes.
    public fun new_for_testing<T>(ctx: &mut TxContext): (TransferPolicy<T>, TransferPolicyCap<T>) {
        let id = object::new(ctx);
        let policy_id = object::uid_to_inner(&id);

        (
            TransferPolicy { id, rules: vec_set::empty(), balance: balance::zero() },
            TransferPolicyCap { id: object::new(ctx), policy_id }
        )
    }
}
