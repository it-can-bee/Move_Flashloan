欢迎交流

我的主页：[博客园](https://www.cnblogs.com/live-passion)

# 项目核心：
### 结构与数据
FlashLender<T>: 核心结构，代表一个具体的贷款机构，维护贷款池(to_lend)、贷款手续费(fee)和唯一标识(id)


Receipt<T>: 代表一次贷款的收据，记录贷款的标识和应还金额


AdminCap: 管理员能力，控制对FlashLender进行管理操作的权限


### 架构设计
（1）创建与管理


（2）放贷和还贷


（3）管理员费率动态调整
