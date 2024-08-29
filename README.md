欢迎交流

我的主页：[博客园](https://www.cnblogs.com/live-passion)

# Move 闪电贷

## 简介

该Move模块在Sui区块链上实现了一个闪电贷机构。闪电贷允许用户在不提供抵押的情况下借用资产，只要他们在同一笔交易中归还资产，保证交易的原子性操作。

## 目录

- [简介](#简介)
- [数据结构](#数据结构)
  - [FlashLender](#flashlender)
  - [Receipt](#receipt-收据)
  - [AdminCap](#admincap-管理员权限)
  - [事件](#事件)
- [项目职能](#functionality)
  - [Creating a Flash Lender](#creating-a-flash-lender)
  - [Requesting a Loan](#requesting-a-loan)
  - [Repaying a Loan](#repaying-a-loan)
  - [Admin-only Functions](#admin-only-functions)
    - [Withdraw Funds](#withdraw-funds)
    - [Deposit Funds](#deposit-funds)
    - [Update Fee](#update-fee)
- [Execution](#execution)
- [Errors](#errors)

## 项目架构
### 结构与数据
FlashLender<T>: 核心结构，代表一个具体的贷款机构，维护贷款池(to_lend)、贷款手续费(fee)和唯一标识(id)
```
struct FlashLender<phantom T> has key {
    id: UID,
    to_lend: Balance<T>,
    treasuryFee: u64,
}
```

Receipt<T>: 作为贷款的凭证。它包含了贷款方的ID以及需要偿还的总金额（包括借款金额和手续费）。
```
struct Receipt<phantom T> {
    flash_lender_id: ID,
    repay_amount: u64,
}
```


AdminCap: 管理员能力，代表管理FlashLender的权限。它包含一个唯一ID和对应FlashLender的ID
```
struct AdminCap has key, store {
    id: UID,
    flash_lender_id: ID,
}
```

Event：模块中定义了多个事件，用于追踪操作：
```
EventLoan：发放贷款时触发。
EventRepay：还款时触发。
EventUpdateFee：更新手续费时触发。
```
### 项目职能
（1）创建管理闪电贷机构
使用new函数创建一个新的闪电贷机构，初始化时需指定可借出的金额和初始手续费百分比；

也可以使用create函数创建一个闪电贷机构并直接存入资金。
```
public fun new<T>(to_lend: Balance<T>, initial_fee_percent: u64, ctx: &mut TxContext): AdminCap
```

（2）放贷和还贷


（2.1）使用loan函数申请贷款。该函数会检查申请金额是否超过可借出的余额，并计算手续费。函数返回借出的金额和一个Receipt（收据）。
```
public fun loan<T>(self: &mut FlashLender<T>, amount: u64, ctx: &mut TxContext): (Coin<T>, Receipt<T>)
```
（2.2）使用repay函数进行还款。该函数会验证还款金额是否正确并匹配收据中的信息，然后将还款金额归还至贷款方的余额中。
```
public fun repay<T>(self: &mut FlashLender<T>, payment: Coin<T>, receipt: Receipt<T>)
/* 允许用户多支付还款金额，并在还款后返回剩余的余额 */
public fun repay_new<T>(self: &mut FlashLender<T>, payment: &mut Coin<T>, receipt: Receipt<T>, ctx: &mut TxContext)
```

（3）管理员


（3.1）提款
```
public fun withdraw<T>(self: &mut FlashLender<T>, admin_cap: &AdminCap, amount: u64, ctx: &mut TxContext): Coin<T>
```
（3.2）存款
```
public entry fun deposit<T>(self: &mut FlashLender<T>, admin_cap: &AdminCap, coin: Coin<T>)
```
（3.3）手续费率动态调整
```
public entry fun update_fee<T>(self: &mut FlashLender<T>, admin_cap: &AdminCap, new_fee: u64, ctx: &mut TxContext)
```

## Error code
```
ELoanTooLarge：请求的贷款超过了可借出的余额。
EInvalidRepaymentAmount：还款金额不正确。
ERepayToWrongLender：还款时指定的贷款方不正确。
EAdminOnly：操作需要管理员权限。
EWithdrawTooLarge：提取金额超过了可提取的余额。
TreasuryFeeTooLarge：手续费超过了允许的最大值。
```
## Execute
### 编译
```mgo move build```
### 部署
```mgo client publish --gas-budget 1000000000```
