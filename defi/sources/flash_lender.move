/* move 闪电贷 */
module defi::flash_lender {
    use mgo::balance::{Self, Balance};
    use mgo::coin::{Self, Coin};
    use mgo::object::{Self, ID, UID};
    use mgo::transfer;
    use mgo::tx_context::{Self, TxContext};
    use mgo::event;

    // 贷款机构 维护贷款池to_lend
    struct FlashLender<phantom T> has key {
        id: UID,
        to_lend: Balance<T>,
        treasuryFee: u64,
    }

    // 烫手山芋模式设计 需要在创建这个的交易期间调用进行被打包or分解
    struct Receipt<phantom T> {
        flash_lender_id: ID,      //借贷方
        repay_amount: u64        //偿还总额：借款金额+费用
    }

    // FlashLender的管理员
    struct AdminCap has key, store {
        id: UID,
        flash_lender_id: ID, //借贷方
    }

    /* event 事件 */
    struct EventLoan has copy, drop {
        sender: address,
        loan_amount: u64
    }

    struct EventRepay has copy, drop {
        sender: address,
        flash_lender_id: ID,
        repay_amount: u64,
        payment_amount_before_repay: u64,
        payment_amount_after_repay: u64,
    }

    struct EventUpdateFee has copy, drop {
        sender: address,
        new_fee: u64,
    }

    //借款超过资金池限制
    const ELoanTooLarge: u64 = 0;
    //偿还除 `repay_amount` 之外的金额（即借入金额 + 费用）
    const EInvalidRepaymentAmount: u64 = 1;
    //还款还错了借贷方
    const ERepayToWrongLender: u64 = 2;
    const EAdminOnly: u64 = 3;
    //提取金额超额
    const EWithdrawTooLarge: u64 = 4;

    // === Creating a flash lender ===
    //放贷 to_lend可借贷
    public fun new<T>(to_lend: Balance<T>, initial_fee_percent: u64, ctx: &mut TxContext): AdminCap {
        let id = object::new(ctx);
        let flash_lender_id = object::uid_to_inner(&id);
        //initial_fee_percent = 300  3%的费率(可调整)
        let flash_lender = FlashLender {
            id,
            to_lend,
            treasuryFee: initial_fee_percent
        };
        //设置共享 方便任何人发起借贷
        transfer::share_object(flash_lender);
        AdminCap { id: object::new(ctx), flash_lender_id }
    }

    //管理员
    public entry fun create<T>(to_lend: Coin<T>, treasuryFee: u64, ctx: &mut TxContext) {
        let balance = coin::into_balance(to_lend);
        let admin_cap = new(balance, treasuryFee, ctx);
        transfer::public_transfer(admin_cap, tx_context::sender(ctx))
    }

    // === Core functionality: requesting a loan and repaying it ===
    // 从贷款池to_lend中提取指定金额amount的贷款 生成收据
    public fun loan<T>(
        self: &mut FlashLender<T>, amount: u64, ctx: &mut TxContext
    ): (Coin<T>, Receipt<T>) {
        let to_lend = &mut self.to_lend;
        assert!(balance::value(to_lend) >= amount, ELoanTooLarge);
        //dynamic fee
        let fee = (amount * self.treasuryFee) / 10000;
        let repay_amount = amount + fee;

        let loan = coin::take(to_lend, amount, ctx);
        let receipt = Receipt { flash_lender_id: object::id(self), repay_amount };

        (loan, receipt)
    }

    //还贷 根据Receipt中记录的信息还款，验证金额正确并归还到贷款池
    public fun repay<T>(self: &mut FlashLender<T>, payment: Coin<T>, receipt: Receipt<T>) {
        let Receipt { flash_lender_id, repay_amount } = receipt;
        //如果还款金额不正确或者`lender`不是`FlashLender`则中止
        assert!(object::id(self) == flash_lender_id, ERepayToWrongLender);
        assert!(coin::value(&payment) == repay_amount, EInvalidRepaymentAmount);

        coin::put(&mut self.to_lend, payment)
    }

    // === Admin-only functionality ===
    //核实操作者是否为管理员
    fun check_admin<T>(self: &FlashLender<T>, admin_cap: &AdminCap) {
        assert!(object::borrow_id(self) == &admin_cap.flash_lender_id, EAdminOnly);
    }

    //从贷款池中提取资金
    public fun withdraw<T>(
        self: &mut FlashLender<T>,
        admin_cap: &AdminCap,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<T> {
        //检查权限 核实操作者是否为管理员
        check_admin(self, admin_cap);
        let to_lend = &mut self.to_lend;
        assert!(balance::value(to_lend) >= amount, EWithdrawTooLarge);
        coin::take(to_lend, amount, ctx)
    }

    public entry fun withdraw_funds<T>
    (
        self: &mut FlashLender<T>,
        admin_cap: &AdminCap,
        amount: u64,
        ctx: &mut TxContext
    )
    {
        let coin = withdraw(self, admin_cap, amount, ctx);
        let sender = tx_context::sender(ctx);
        transfer::public_transfer(coin, sender);
    }

    //向贷款池中添加资金
    public entry fun deposit<T>(
        self: &mut FlashLender<T>, admin_cap: &AdminCap, coin: Coin<T>
    ) {
        check_admin(self, admin_cap);
        coin::put(&mut self.to_lend, coin);
    }

    // 更新fee手续费
    public entry fun update_fee<T>(
        self: &mut FlashLender<T>, admin_cap: &AdminCap, new_fee: u64, ctx: &mut TxContext
    ) {
        check_admin(self, admin_cap);
        self.treasuryFee = new_fee;
        event::emit(EventUpdateFee{sender: tx_context::sender(ctx), new_fee});
    }

    // === Reads ===
    public fun get_fee<T>(self: &FlashLender<T>): u64 {
        self.treasuryFee
    }

    public fun get_max_loan<T>(self: &FlashLender<T>): u64 {
        balance::value(&self.to_lend)
    }

    public fun get_repay_amount<T>(self: &Receipt<T>): u64 {
        self.repay_amount
    }

    public fun get_flash_lender_id<T>(self: &Receipt<T>): ID {
        self.flash_lender_id
    }

    public fun repay_new<T>(self: &mut FlashLender<T>, payment: &mut Coin<T>, receipt: Receipt<T>, ctx: &mut TxContext) {

        let Receipt { flash_lender_id, repay_amount } = receipt;
        assert!(object::id(self) == flash_lender_id, ERepayToWrongLender);
        let payment_amount = coin::value(payment);
        assert!(payment_amount  >= repay_amount, EInvalidRepaymentAmount);

        let paid = coin::split(payment, repay_amount, ctx);
        coin::put(&mut self.to_lend, paid);
        let sender = tx_context::sender(ctx);

        event::emit(EventRepay{
            sender: sender,
            flash_lender_id: flash_lender_id,
            repay_amount: repay_amount,
            payment_amount_before_repay: payment_amount,
            payment_amount_after_repay: coin::value(payment)
        });
    }

    public entry fun loan_and_repay<T>(self: &mut FlashLender<T>, amount: u64,
                                       payment: &mut Coin<T>, ctx: &mut TxContext) {

        let (coin, receipt) = loan(self, amount, ctx);
        let sender = tx_context::sender(ctx);
        coin::join(payment, coin);

        event::emit(EventLoan{
            sender: sender,
            loan_amount: amount
        });

        repay_new(self, payment, receipt, ctx);
    }


}
