from __future__ import annotations

from enum import StrEnum
from dataclasses import dataclass
from functools import wraps
from typing import Protocol, Self, Any, Callable
from abc import ABC, abstractmethod
from decimal import Decimal

from sqlmodel import Session


# ==============================================================================
# 🎯 DDD 架构核心设计
# 1. 分层与依赖倒置：领域层（Domain）绝对纯净，不依赖任何外部框架和数据库。
#    基础设施层（Infra）通过实现领域层定义的 Protocol 接口，反向依赖领域层。
# 2. 异常控制权：只有“实体（Entity）”有资格抛出业务异常。值对象（Value Object）
#    只负责返回 True/False 状态，因为脱离语境的“状态”不应直接决定业务报错。
# 3. 依赖传参：实体绝不把 Service/Repository 存为 self 属性，避免序列化爆炸和内存泄漏。
#    所有的 Infra 依赖都通过方法参数显式传入，用完即弃。
# ==============================================================================

# =========================================================
# 💡 架构设计探讨：为什么领域模型能调用基础设施接口？
#
# 很多人认为，纯正的 DDD 中实体（Entity）绝对不能让基础设施（Infra）入侵。
# 但在实际工业级落地中，我们采用的是【实用化 DDD 妥协方案】：
#
# 1. 依赖倒置（DIP）：实体依赖的是 Protocol（接口），而不是具体的 MySQL/HTTP 客户端。
#    这保证了领域层在类型上是绝对解耦的。
# 2. 显式依赖注入：通过方法参数传入（如 change_name(user_infra)），保证实体在内存中无状态残留。
# 3. 无副作用原则（最核心）：虽然事务边界由 UoW 在应用层统一控制，
#    但领域模型所依赖的这些 Infra 接口，必须严格保证是【只读、幂等、无副作用】的
#    （比如：查汇率、查敏感词、查账户是否存在）。
#    真正的“写副作用”（如发 MQ、发短信、扣库存落库、提交 commit），
#    必须严格放在应用服务（Application Service）中。
#    否则，业务规则会散落在各个实体中引发“霰弹式修改”，也让领域模型变得极其难以测试和推演。
# =========================================================

# ==============================================================================
# 💡 Python 类型系统与 DDD 的结合
#
# 为什么资源库（Repository）用 ABC 定义，而基础设施接口（InfraService）用 Protocol？
# 1. 【资源库用 ABC】：代表“强制继承”与“血缘契约”。具体的数据库实现（如 SQLUserRepository）
#    必须继承此基类，并严格按照签名实现所有方法，否则实例化时直接报错。这适合底层基础设施。
# 2. 【InfraService 用 Protocol】：代表“鸭子类型”与“能力需求”。领域层（Domain）不需要知道
#    传进来的对象是什么类，只要它实现了所需的这些方法（能力），就能在类型检查器中完美通过。
#    这也是为什么领域层极度纯净，因为它只依赖“协议（Protocol）”，不依赖“具体类（ABC）”。
# ==============================================================================

# ==========================================
# 1. 基础设施接口定义 (Ports) - 保持纯净
# ==========================================
class UserInfraService(Protocol):
    """用户领域层需要的只读、幂等、无副作用的基础设施接口"""

    # 这玩意也是API，领域层不能有慢依赖
    # def is_safe(self, text: str) -> bool: ...

    def accounts_exists(self, account_ids: set[int]) -> bool: ...

    def account_exists(self, account_id: int) -> bool: ...

    # WARNING 不是资源库模式的不能有
    # def get_exchange_rate(self, f_currency: "Currency", t_currency: "Currency") -> Decimal: ...

    # WARNING 禁止一个聚合以任何手段获得另一个聚合
    # def get_total_account(self, uids: set[int]) -> list["Account"]: ...
    # def get_account(self, uid: int) -> "Account | None": ...

    def get_user(self, uid: int) -> "User | None": ...


class AccountInfraService(Protocol):
    """账户领域层需要的接口"""

    # def get_exchange_rate(self, f_currency: "Currency", t_currency: "Currency") -> Decimal: ...

    def get_account(self, uid: int) -> "Account | None": ...

    def get_total_account(self, user_id) -> list[Account]: ...


# ==========================================
# 2. 领域异常定义
# ==========================================
class DomainException(Exception):
    """领域层业务异常基类"""

    def __init__(self, entity: str, message: str):
        self.entity = entity
        self.message = message
        super().__init__(f"{entity}: {message}")


class UserException(DomainException):
    def __init__(self, message: str): super().__init__("User", message)


class AccountException(DomainException):
    def __init__(self, message: str): super().__init__("Account", message)


# ==========================================
# 3. 领域模型 (充血模型)
# ==========================================
USER_NAME_MAX_LAN = 8


class DomainEntity(ABC):
    """实体基类：统一管理 ID 和乐观锁版本号"""

    def __init__(self, uid: int, version: int):
        self._uid = uid
        self._version = version

    @property
    def uid(self) -> int: return self._uid

    @property
    def version(self) -> int: return self._version

    @classmethod
    @abstractmethod
    def get(cls, uid: int, infra: Any) -> Self:
        """抽象工厂方法，强制子类实现获取逻辑"""
        ...


class Currency(StrEnum):
    CNY = "CNY"
    USD = "USD"


@dataclass(slots=True, frozen=True)
class Name:
    """值对象：不可变，保证线程安全。只能返回状态，绝不能 raise 业务异常。"""
    first_name: str
    last_name: str

    def __str__(self):
        return f"{self.first_name} {self.last_name}"

    # 反正是应用服务层直接调用api了，就不需要值对象里面再判断了
    # 虽然自己检查自己是否合法听上去还是很好的，但是模型里面不能有慢依赖
    # def is_safe(self, infra: UserInfraService) -> bool:
    #     return infra.is_safe(str(self))

    def length_is_valid(self) -> bool:
        return len(str(self)) <= USER_NAME_MAX_LAN


class User(DomainEntity):
    def __init__(self, uid: int, name: Name, version: int):
        super().__init__(uid, version)
        self._name = name

    @property
    def name(self) -> str:
        return str(self._name)

    @classmethod
    def get(cls, uid: int, infra: UserInfraService) -> "User":
        user = infra.get_user(uid)
        if not user:
            # 💡 实体有资格抛异常，因为“用户不存在”是明确的业务失败
            raise UserException(f"user with uid {uid} does not exist")
        return user

    # 改名字的时候直接从应用服务层传来这个名字合不合法
    def change_name(self, new_first_name: str, new_last_name: str, safe: bool):
        if not safe:
            raise UserException("the name contains unsafe characters")

        new_name = Name(new_first_name, new_last_name)
        if not new_name.length_is_valid():
            raise UserException(f"User name is too long, max is {USER_NAME_MAX_LAN}")
        self._name = new_name

    # WARNING 一个聚合去尝试访问另一个聚合是十分危险的，考虑以下的情景
    # A聚合，B聚合版本号都为1，此时通过A聚合去访问了B聚合，并基于B聚合中的数据做出了判断，修改了A聚合
    # 此时A的版本号变为2，若这过程中有其他线程修改了B聚合，则B聚合版本号也变为2
    # 最后尝试保存A聚合，因为没有其他线程在这之间修改过A聚合，所以保存成功，但是此次变更却参考了过时的B聚合
    # 所以禁止聚合获取另一个聚合，必须通过领域服务编排


# app/query
class AccountQuery:
    """读端，可以直接写SQL，怎么方便怎么来"""

    def __init__(self, uow: UnitOfWork):
        # NOTE 直接拿着uow。而且读端没有事务，直接方法里面自己开session
        self.uow = uow

    # NOTE 因为禁止User以任何手段获取Account聚合，所以get_total_account和get_account方法都从协议中被去掉了
    # 那么如何实现查看全部的金额呢？这个其实是读端的业务（因为只是展示，具体的转账，冻结等都是基于某一个特定的账户而不是总金额）
    # 所以AccountCenter也完全是不必要的，直接改为读写分离

    def get_total_balance(
            self,
            infra: AccountInfraService,
            get_exchange_rate: ExternalRateAPI,
            user_id: int,
            currency: Currency
    ) -> Decimal:
        with self.uow.query():  # type: ignore
            accounts = infra.get_total_account(user_id)
            rates = {
                c: get_exchange_rate(c, currency)
                for c in {a.currency for a in accounts}
            }
            return Decimal(sum(a.balance * rates[a.currency] for a in accounts))


class Account(DomainEntity):
    def __init__(self, uid: int, balance: Decimal, currency: Currency, foreign_key_to_user: int, version: int):
        super().__init__(uid, version)
        self._balance = balance
        self._currency = currency
        self._foreign_key_to_user = foreign_key_to_user

    # 还需要bind_to_user吗？我看不需要了，因为foreign_key_to_user参数必须要求传入才行，不需要再有bind_to_use方法了
    # 解绑的话实际上是软删除。而不是直接设置foreign_key_to_user为-1，而且解绑的前置条件是Account的balance为0，这部分先不展开了

    # 如何保证foreign_key_to_user是有效的？创建Account的时候必须是从资源库中取出一个User，然后foreign_key_to_user=user.uid
    # 但是如果user突然被删除了呢，那就需要定时对账去软删除，常规的检查是覆盖不了这个TOCTOU的

    @property
    def balance(self) -> Decimal:
        return self._balance

    @property
    def currency(self) -> Currency:
        return self._currency

    @property
    def foreign_key_to_user(self) -> int:
        return self._foreign_key_to_user

    @classmethod
    def get(cls, uid: int, infra: AccountInfraService) -> "Account":
        account = infra.get_account(uid)
        if not account:
            raise AccountException(f"account with uid {uid} does not exist")
        return account

    def increase_balance(self, rate: Decimal, amount: Decimal):
        self._balance += amount * rate

    def decrease_balance(self, rate: Decimal, amount: Decimal):
        new_balance = self._balance - (amount * rate)
        if new_balance < 0:
            raise AccountException("the balance can't less than 0")
        self._balance = new_balance


# ==========================================
# 4. 领域服务 (Domain Service)
# ==========================================
class TransferService:
    """核心业务规则：负责跨聚合根（User 和 Account）的协调。"""

    def __init__(self, account_infra: AccountInfraService):
        self.account_infra = account_infra

    # NOTE 虽然经过这些改动，已经意识到了转账实际上是账户到账户，但是from_user语义上读起来更顺畅（动作的发起者），而且也能用，就不改了
    def transfer(
            self,
            from_user: User,
            to_user: User,
            from_account_id: int,
            to_account_id: int,
            from_rate: Decimal,
            to_rate: Decimal,
            amount: Decimal
    ) -> tuple[Account, Account]:
        from_account = Account.get(from_account_id, self.account_infra)
        if from_account.foreign_key_to_user != from_user.uid:
            raise AccountException(f"Account #{from_account_id} and  User #{from_user.uid} don't match")

        to_account = Account.get(to_account_id, self.account_infra)
        if to_account.foreign_key_to_user != to_user.uid:
            raise AccountException(f"Account #{to_account} and  User #{to_user.uid} don't match")

        from_account.decrease_balance(from_rate, amount)
        to_account.increase_balance(to_rate, amount)

        return from_account, to_account


# ==========================================
# 5. 资源库与外部服务定义 (ABCs)
# ==========================================
class UserRepository(ABC):
    @abstractmethod
    def get_user(self, uid: int) -> "User | None": ...

    @abstractmethod
    def save_user(self, user: "User") -> None: ...


class AccountRepository(ABC):
    @abstractmethod
    def get_account(self, uid: int) -> "Account | None": ...

    @abstractmethod
    def save_account(self, account: "Account") -> None: ...

    @abstractmethod
    def get_total_account(self, uids: set[int]) -> list["Account"]: ...

    @abstractmethod
    def account_exists(self, account_id: int) -> bool: ...

    @abstractmethod
    def accounts_exists(self, account_ids: set[int]) -> bool: ...

    @abstractmethod
    def update_balance(self, account_id: int, delta: Decimal, expected_currency: Currency) -> bool: ...


# WARNING 资源库模式是像集合一样给上层提供具备业务语义的方法来操控缓存和数据库等的
# 所以API不算在资源库里面，必须走网关模式。而且api都是无状态的，几乎不需要用类封装
# Google：一个核心后端服务通常会主动调用 3 到 10 个 不同的下游微服务 API
# 不算多，直接用函数作为参数注入得了

class ExternalRateAPI(ABC):
    # 直接改成函数调用，用Protocol因为函数不能做继承了
    def __call__(self, f_currency: str, t_currency: str) -> Decimal: ...


class ExternalSensitiveWordAPI(ABC):
    def __call__(self, text: str) -> bool: ...


# ==========================================
# 6. 基础设施具体实现 (Infrastructure)
# ==========================================
class SQLUserRepository(UserRepository):
    def __init__(self, uow: "UnitOfWork"):
        self.uow = uow

    def get_user(self, uid: int) -> "User | None":
        session = self.uow.session
        # TODO: 真实 SQL 逻辑
        return None

    def save_user(self, user: "User") -> None: ...


class SQLAccountRepository(AccountRepository):
    def __init__(self, uow: "UnitOfWork"):
        self.uow = uow

    def get_account(self, uid: int) -> "Account | None":
        return None

    def save_account(self, account: "Account") -> None: ...

    def get_total_account(self, uids: set[int]) -> list["Account"]:
        return []

    def account_exists(self, account_id: int) -> bool: return False

    def accounts_exists(self, account_ids: set[int]) -> bool: return False

    def update_balance(self, account_id: int, delta: Decimal, expected_currency: Currency) -> bool:
        return False


from typing import ParamSpec, TypeVar

T = TypeVar("T")
P = ParamSpec("P")


class GateWayException(Exception):
    """网关层异常基类"""

    def __init__(self, api_type: str, func_name: str, message: str):
        self.api_type = api_type
        self.func_name = func_name
        self.message = message
        super().__init__(f"{api_type} - {func_name}: {message}")


class TimeOutError(GateWayException):
    def __init__(self, api_type: str, func_name: str, message: str):
        super().__init__(api_type, func_name, message)


# 只负责网关层异常
def retry(n: int) -> Callable[[Callable[[P], T]], Callable[[P], T]]:
    if n <= 0: raise ValueError("n must be greater than 0")

    def decorator(func: Callable[[P], T]) -> Callable[[P], T]:
        @wraps(func)
        def wrapper(*args: P.args, **kwargs: P.kwargs) -> T:
            for _ in range(n - 1):
                try:
                    return func(*args, **kwargs)
                except GateWayException:
                    pass

            return func(*args, **kwargs)

        return wrapper

    return decorator


# 同理
def timeout(second: int): ...


def get_exchange_rate_api(f_currency: str, t_currency: str) -> Decimal:
    return Decimal("1.0")


def is_safe_api(text: str) -> bool:
    return True


# ==========================================
# 8. 工作单元 (Unit of Work)
# ==========================================

from contextlib import contextmanager


class UnitOfWork:
    """
    工作单元：管理数据库 Session 的生命周期。
    利用上下文管理器 __exit__ 统一提交或回滚，防止应用层乱写 commit。
    """

    def __init__(self, session_factory):
        self.session_factory = session_factory
        self.session: Session | None = None

    # 有事务，给写模型用的
    @contextmanager
    def command(self):
        try:
            self.session = self.session_factory()
            self.session.begin()
            yield self
            self.session.commit()
        except Exception:
            self.session.rollback()
            # 和__exit__的默认return False保持一致，将异常传递给上层
            raise
        finally:
            self.session.close()

    # 无事务，给读模型用的
    @contextmanager
    def query(self):
        try:
            self.session = self.session_factory()
            yield self
        finally:
            self.session.close()


# ==========================================
# 9. 应用服务 (Application Service)
# ==========================================
# app/command

class ApplicationError(Exception):
    pass


class TransferServiceErr(ApplicationError):
    pass


class TransferAppService:
    """
    应用服务：只负责流程编排和事务边界，绝对不包含业务规则。
    """

    # NOTE 直接拿着函数就行，但是如果参数越来越多，可以考虑这样
    # T = TypeVar("T", bound=Callable)
    # 初始化时候接收api: dict[type[T], T]
    # 然后可以传入{ExternalRateAPI: get_exchange_rate_api}
    # 就能通过self.api[ExternalRateAPI](...)来调用了，依旧只依赖接口
    # repo、infra（实际上是专供领域层可以调用的只读资源库）相关同理
    # 这里传入的ExternalRateAPI就可以是被装饰器装饰过的，比如最大超时时间5s且重试3次
    # 应用服务层也别管异常了（除非是要统一包装）

    def __init__(
            self,
            uow: UnitOfWork,
            user_repo: UserRepository,
            account_repo: AccountRepository,
            user_infra: UserInfraService,
            account_infra: AccountInfraService,
            get_exchange_rate: ExternalRateAPI
    ):
        self.uow = uow
        self.user_repo = user_repo
        self.account_repo = account_repo
        self.user_infra = user_infra
        self.account_infra = account_infra
        self.get_exchange_rate = get_exchange_rate

    def execute_transfer(
            self,
            from_uid: int,
            to_uid: int,
            from_account_id: int,
            to_account_id: int,
            amount: Decimal,
            currency: Currency
    ) -> tuple[Account, Account]:
        with self.uow.query():  # type: ignore
            from_account = Account.get(from_account_id, self.account_infra)
            to_account = Account.get(to_account_id, self.account_infra)

        from_rate = self.get_exchange_rate(currency, from_account.currency)
        if from_account.currency == to_account.currency:
            to_rate = from_rate
        else:
            to_rate = self.get_exchange_rate(currency, to_account.currency)

        transfer_service = TransferService(self.account_infra)

        with self.uow.command():  # type: ignore
            from_user = User.get(from_uid, self.user_infra)
            to_user = User.get(to_uid, self.user_infra)

            original_from_account = Account.get(from_account_id, self.account_infra)
            original_to_account = Account.get(to_account_id, self.account_infra)

            latest_from_account, latest_to_account = transfer_service.transfer(
                from_user, to_user,
                from_account_id, to_account_id,
                from_rate, to_rate,
                amount
            )

            from_delta = latest_from_account.balance - original_from_account.balance
            to_delta = latest_to_account.balance - original_to_account.balance

            # NOTE 币种用事务外那次读到的（from_account / to_account），
            #      不能用 latest_*。汇率是按事务外的币种算的，
            #      条件更新里带上币种，币种一变就 0 行，比版本号精确。
            if from_account_id < to_account_id:
                rows1 = self.account_repo.update_balance(from_account_id, from_delta, from_account.currency)
                rows2 = self.account_repo.update_balance(to_account_id, to_delta, to_account.currency)
            else:
                rows2 = self.account_repo.update_balance(to_account_id, to_delta, to_account.currency)
                rows1 = self.account_repo.update_balance(from_account_id, from_delta, from_account.currency)

            if rows1 == 0 or rows2 == 0:
                raise TransferServiceErr("concurrency conflict, please retry")

        return latest_from_account, latest_to_account
