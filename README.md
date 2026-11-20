# backend-architecture-notes

![notes](https://img.shields.io/badge/notes-8-4a7c59)
![focus](https://img.shields.io/badge/focus-DDD%20%C2%B7%20Distributed%20Tx%20%C2%B7%20TLA%2B-555)

后端架构笔记：DDD 落地取舍、分布式事务、TLA+ 形式化验证。

不是教程。这里记的是读过书、写过代码之后自己的判断，每条尽量把代价一起写上。

## 目录

### 01 DDD

- [x] [聚合边界如何划分](./01-ddd/01-aggregate-boundary.md)：一致性边界，拆与不拆的成本不对称
- [x] [分层：Repository、Mapper 与依赖方向](./01-ddd/02-repository-mapper.md)：一个请求从路由到数据库要经过哪几层
- [x] [为什么不用全自动的 UoW](./01-ddd/03-uow-tradeoff.md)：diff 在复杂模型里撑不住，改成聚合根收集事件

### 02 分布式事务

- [x] [TCC：用状态机处理三类异常](./02-distributed-tx/01-tcc.md)：不建模超时，任意时刻可 Cancel，用状态覆盖空回滚和悬挂
- [x] [Saga：补偿不是回滚](./02-distributed-tx/02-saga.md)：软状态保护、超时取消，只有失败那步会出空回滚和悬挂
- [x] [Outbox：事务发件箱模式](./02-distributed-tx/03-outbox.md)：状态只要四种，Processing 用行锁替掉，先投递再改状态

### 03 TLA+

- [x] [语法与技巧](./03-tla+/01-syntax_and_techniques.md)：常量转变量、多重集分配、状态空间切分、强弱公平性、探针
- [x] [能验证什么，不能验证什么](./03-tla+/02-what_and_what_not.md)：不变式、时序、精化的能力，以及抽象、公平性、代码一致性上的边界
- [ ] 一个消息队列规约的解读

### 04 系统设计

- [ ] 短链服务
- [ ] 秒杀系统

## 代码

`examples/` 里放着笔记引用的示例，都能编译或跑起来。

```
examples/
├── ddd_v1.py          User 聚合持有 AccountCenter 的第一版
├── ddd_v2.py          重构后：读写分离、汇率当参数传
├── router_example.py  v2 的 FastAPI 接口层
├── tcc/
│   ├── TCC.tla        TCC 规约
│   └── TCC.cfg
├── saga/
│   ├── Saga.tla       Saga 规约
│   └── Saga.cfg
├── outbox/
│   ├── Outbox.tla     Outbox 规约
│   └── Outbox.cfg
└── tla+/
    ├── Subset.tla     常量转变量
    ├── Allocation.tla 多重集分配
    └── TwoWorkers.tla 超组合，OnlyOnce 故意被违反
```

三个规约和 `tla+` 下那几个小例子的跑法一样，在各自的目录里执行：

```
# examples/tcc
java -cp ~/tla2tools.jar tlc2.TLC -deadlock -config TCC.cfg TCC.tla

# examples/saga
java -cp ~/tla2tools.jar tlc2.TLC -deadlock -config Saga.cfg Saga.tla

# examples/outbox
java -cp ~/tla2tools.jar tlc2.TLC -deadlock -config Outbox.cfg Outbox.tla
```

## 说明

这些是学习过程中的整理，不是生产代码。示例里的 `SessionLocal`、`update_balance` 之类的实现是空的，用于说明结构，不保证能直接接数据库。

引用书里的伪代码时，会在小节里注明出处。有错误欢迎提 issue。

## 主要参考

《实现领域驱动设计》《企业应用架构模式》《架构整洁之道》《数据密集型应用系统设计》，以及 TLA+ 官方文档。
