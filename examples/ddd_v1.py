"""DDD 分层的 v1：User 聚合持有 AccountCenter 值对象。

这一版是"引子"。它看起来挺自然：用户能判断账户归属，也能算总资产。
但它违反了一条规则：聚合之间不能互相获取。

v2 见 ddd_v2.py，那里把 AccountCenter 拆掉，改成了读写分离。
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from decimal import Decimal
from enum import StrEnum
from typing import Any, Protocol, Self


# ==========================================
# 1. 基础设施接口定义 (Ports)
# ==========================================
class UserInfraService(Protocol):
    """用户领域层需要的只读、幂等、无副作用的基础设施接口"""

    def is_safe(self, text: str) -> bool: ...

    def accounts_exists(self, account_ids: set[int]) -> bool: ...

    def account_exists(self, account_id: int) -> bool: ...

    def get_exchange_rate(self, f_currency: "Currency", t_currency: "Currency") -> Decimal: ...

    def get_total_account(self, uids: set[int]) -> list["Account"]: ...

    def get_account(self, uid: int) -> "Account | None": ...

    def get_user(self, uid: int) -> "User | None": ...


class AccountInfraService(Protocol):
    def get_exchange_rate(self, f_currency: "Currency", t_currency: "Currency") -> Decimal: ...

    def get_account(self, uid: int) -> "Account | None": ...


# ==========================================
# 2. 领域异常
# ==========================================
class DomainException(Exception):
    """领域层业务异常基类"""

    def __init__(self, entity: str, message: str):
        self.entity = entity
        self.message = message
        super().__init__(f"{entity}: {message}")


class UserException(DomainException):
    def __init__(self, message: str):
        super().__init__("User", message)


class AccountException(DomainException):
    def __init__(self, message: str):
        super().__init__("Account", message)


# ==========================================
# 3. 领域模型
# ==========================================
USER_NAME_MAX_LAN = 8


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

    def is_safe(self, infra: UserInfraService) -> bool:
        return infra.is_safe(str(self))

    def length_is_valid(self) -> bool:
        return len(str(self)) <= USER_NAME_MAX_LAN


class DomainEntity(ABC):
    """实体基类：统一管理 ID 和乐观锁版本号"""

    def __init__(self, uid: int, version: int):
        self._uid = uid
        self._version = version

    @property
    def uid(self) -> int:
        return self._uid

    @property
    def version(self) -> int:
        return self._version

    def increase_version(self) -> int:
        self._version += 1
        return self.version

    @classmethod
    @abstractmethod
    def get(cls, uid: int, infra: Any) -> Self:
        ...


class User(DomainEntity):
    def __init__(self, uid: int, name: Name, account_center: "AccountCenter", version: int):
        super().__init__(uid, version)
        self._name = name
        self.account_center = account_center

    @property
    def name(self) -> str:
        return str(self._name)

    @classmethod
    def get(cls, uid: int, infra: UserInfraService) -> "User":
        user = infra.get_user(uid)
        if not user:
            raise UserException(f"user with uid {uid} does not exist")
        return user

    def change_name(self, new_first_name: str, new_last_name: str, infra: UserInfraService):
        new_name = Name(new_first_name, new_last_name)
        if not new_name.is_safe(infra):
            raise UserException("the name contains unsafe characters")
        if not new_name.length_is_valid():
            raise UserException(f"User name is too long, max is {USER_NAME_MAX_LAN}")
        self._name = new_name

    def bind_accounts(self, new_account_ids: set[int], infra: UserInfraService):
        new_account_center = AccountCenter(new_account_ids)
        if not new_account_center.accounts_exists(infra):
            raise UserException("at least one account is not exists")
        if not new_account_center.all_account_bind_with_the_user(self.uid, infra):
            raise UserException("at least one account is not subordinate to the user")
        self.account_center = new_account_center

    def add_account(self, account_id: int, infra: UserInfraService):
        new_account_center, ok = self.account_center.add_account(self.uid, account_id, infra)
        if not ok:
            raise UserException(f"the #{account_id} account is unavailable or not subordinate")
        self.account_center = new_account_center

    def remove_account(self, account_id: int):
        self.account_center = self.account_center.remove_account(account_id)


@dataclass(slots=True, frozen=True)
class AccountCenter:
    """值对象：账户集合，封装了集合运算和校验状态"""

    account_ids: set[int]

    def accounts_exists(self, infra: UserInfraService) -> bool:
        return infra.accounts_exists(self.account_ids)

    def include_account(self, account_id: int) -> bool:
        return account_id in self.account_ids

    def add_account(
        self, target_user: int, account_id: int, infra: UserInfraService
    ) -> tuple["AccountCenter | None", bool]:
        if not infra.account_exists(account_id):
            return None, False
        acc = infra.get_account(account_id)
        if not acc or acc.foreign_key_to_user != target_user:
            return None, False
        return AccountCenter(self.account_ids | {account_id}), True

    def remove_account(self, account_id: int) -> "AccountCenter":
        return AccountCenter(self.account_ids - {account_id})

    def get_total_balance(self, infra: UserInfraService, currency: Currency) -> Decimal:
        return Decimal(
            sum(
                account.balance * infra.get_exchange_rate(account.currency, currency)
                for account in infra.get_total_account(self.account_ids)
            )
        )

    def all_account_bind_with_the_user(self, target_user: int, infra: UserInfraService) -> bool:
        accounts = infra.get_total_account(self.account_ids)
        if not accounts:
            return True
        return not any(account.foreign_key_to_user != target_user for account in accounts)


class Account(DomainEntity):
    def __init__(self, uid: int, balance: Decimal, currency: Currency, foreign_key_to_user: int, version: int):
        super().__init__(uid, version)
        self._balance = balance
        self._currency = currency
        self._foreign_key_to_user = foreign_key_to_user

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

    def increase_balance(self, amount: Decimal, currency: Currency, infra: AccountInfraService):
        rate = infra.get_exchange_rate(currency, self.currency)
        self._balance += amount * rate

    def decrease_balance(self, amount: Decimal, currency: Currency, infra: AccountInfraService):
        rate = infra.get_exchange_rate(currency, self.currency)
        new_balance = self._balance - (amount * rate)
        if new_balance < 0:
            raise AccountException("the balance can't less than 0")
        self._balance = new_balance


# ==========================================
# 4. 领域服务
# ==========================================
class TransferService:
    """核心业务规则：负责跨聚合根（User 和 Account）的协调。"""

    def __init__(self, account_infra: AccountInfraService):
        self.account_infra = account_infra

    def transfer(
        self,
        from_user: User,
        to_user: User,
        from_account_id: int,
        to_account_id: int,
        amount: Decimal,
        currency: Currency,
    ) -> tuple[Account, Account]:
        # 从这个版本开始，归属判断是通过 User 聚合里的 AccountCenter 做的。
        # 这正是 v2 要拆掉的地方。
        if not from_user.account_center.include_account(from_account_id):
            raise UserException(f"User {from_user.uid} doesn't own account {from_account_id}")
        if not to_user.account_center.include_account(to_account_id):
            raise UserException(f"User {to_user.uid} doesn't own account {to_account_id}")

        from_account = Account.get(from_account_id, self.account_infra)
        to_account = Account.get(to_account_id, self.account_infra)

        from_account.decrease_balance(amount, currency, self.account_infra)
        to_account.increase_balance(amount, currency, self.account_infra)

        return from_account, to_account


# ==========================================
# 5. 资源库与外部服务定义
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


class ExternalRateAPI(ABC):
    @abstractmethod
    def get_exchange_rate(self, f_currency: str, t_currency: str) -> Decimal: ...


class ExternalSensitiveWordAPI(ABC):
    @abstractmethod
    def is_safe(self, text: str) -> bool: ...


# ==========================================
# 6. 基础设施具体实现
# ==========================================
class SQLUserRepository(UserRepository):
    def __init__(self, uow: "UnitOfWork"):
        self.uow = uow

    def get_user(self, uid: int) -> "User | None":
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

    def account_exists(self, account_id: int) -> bool:
        return False

    def accounts_exists(self, account_ids: set[int]) -> bool:
        return False


class RateAPIClient(ExternalRateAPI):
    def get_exchange_rate(self, f_currency: str, t_currency: str) -> Decimal:
        return Decimal("1.0")


class SensitiveWordAPIClient(ExternalSensitiveWordAPI):
    def is_safe(self, text: str) -> bool:
        return True


# ==========================================
# 7. 防腐层适配器
# ==========================================
class InfraAdapter(UserInfraService):
    """把碎片的 Repository 和 API 适配成领域层需要的协议。"""

    def __init__(
        self,
        user_repo: UserRepository,
        account_repo: AccountRepository,
        rate_api: ExternalRateAPI,
        sensitive_api: ExternalSensitiveWordAPI,
    ):
        self._user_repo = user_repo
        self._account_repo = account_repo
        self._rate_api = rate_api
        self._sensitive_api = sensitive_api

    def get_user(self, uid: int) -> "User | None":
        return self._user_repo.get_user(uid)

    def get_account(self, uid: int) -> "Account | None":
        return self._account_repo.get_account(uid)

    def get_total_account(self, uids: set[int]) -> list["Account"]:
        return self._account_repo.get_total_account(uids)

    def account_exists(self, account_id: int) -> bool:
        return self._account_repo.account_exists(account_id)

    def accounts_exists(self, account_ids: set[int]) -> bool:
        return self._account_repo.accounts_exists(account_ids)

    def is_safe(self, text: str) -> bool:
        return self._sensitive_api.is_safe(text)

    def get_exchange_rate(self, f_currency: Currency, t_currency: Currency) -> Decimal:
        return self._rate_api.get_exchange_rate(f_currency.value, t_currency.value)


# ==========================================
# 8. 工作单元（v1 只有写事务）
# ==========================================
class UnitOfWork:
    def __init__(self, session_factory):
        self.session_factory = session_factory
        self.session = None

    def __enter__(self) -> "UnitOfWork":
        self.session = self.session_factory()
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        if exc_type:
            self.session.rollback()
        else:
            self.session.commit()
        self.session.close()


# ==========================================
# 9. 应用服务
# ==========================================
class TransferAppService:
    def __init__(
        self,
        uow: UnitOfWork,
        user_repo: UserRepository,
        account_repo: AccountRepository,
        infra_adapter: UserInfraService,
        transfer_service: TransferService,
    ):
        self.uow = uow
        self.user_repo = user_repo
        self.account_repo = account_repo
        self.infra = infra_adapter
        self.transfer_service = transfer_service

    def execute_transfer(
        self,
        from_uid: int,
        to_uid: int,
        from_account_id: int,
        to_account_id: int,
        amount: Decimal,
        currency: Currency,
    ) -> tuple[Account, Account]:
        with self.uow:
            from_user = User.get(from_uid, self.infra)
            to_user = User.get(to_uid, self.infra)

            from_account, to_account = self.transfer_service.transfer(
                from_user, to_user, from_account_id, to_account_id, amount, currency
            )

            self.account_repo.save_account(from_account)
            self.account_repo.save_account(to_account)

            return from_account, to_account
