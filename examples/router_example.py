"""接口层示例：把 ddd_architecture_example 里的应用服务暴露成 HTTP 接口。

运行：
    pip install fastapi uvicorn
    uvicorn router_example:app --reload

注意：SessionLocal 是占位，真实项目里换成自己的 session 工厂。
"""

from decimal import Decimal

from fastapi import APIRouter, Depends, FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel

from ddd_architecture_example import (
    Currency,
    DomainException,
    InfraAdapter,
    RateAPIClient,
    SensitiveWordAPIClient,
    SQLAccountRepository,
    SQLUserRepository,
    TransferAppService,
    TransferService,
    UnitOfWork,
)

app = FastAPI(title="DDD 分层示例")
router = APIRouter(prefix="/transfer", tags=["transfer"])


def SessionLocal():
    """占位：真实项目里返回 SQLAlchemy Session 或数据库连接。"""
    raise NotImplementedError("wire your own session factory")


class TransferRequest(BaseModel):
    from_uid: int
    to_uid: int
    from_account_id: int
    to_account_id: int
    amount: Decimal
    currency: Currency


class TransferResponse(BaseModel):
    from_account_id: int
    from_balance: Decimal
    to_account_id: int
    to_balance: Decimal


def get_transfer_service() -> TransferAppService:
    """每个请求一套新对象：UoW 持有 Session，不能跨请求共享。"""
    uow = UnitOfWork(SessionLocal)
    user_repo = SQLUserRepository(uow)
    account_repo = SQLAccountRepository(uow)
    infra = InfraAdapter(
        user_repo,
        account_repo,
        RateAPIClient(),
        SensitiveWordAPIClient(),
    )
    domain_service = TransferService(infra)
    return TransferAppService(uow, user_repo, account_repo, infra, domain_service)


@router.post("", response_model=TransferResponse)
def transfer(
    req: TransferRequest,
    service: TransferAppService = Depends(get_transfer_service),
) -> TransferResponse:
    from_account, to_account = service.execute_transfer(
        req.from_uid,
        req.to_uid,
        req.from_account_id,
        req.to_account_id,
        req.amount,
        req.currency,
    )
    return TransferResponse(
        from_account_id=from_account.uid,
        from_balance=from_account.balance,
        to_account_id=to_account.uid,
        to_balance=to_account.balance,
    )


@app.exception_handler(DomainException)
async def handle_domain_exception(request, exc: DomainException):
    """业务异常统一转 400，路由里就不用写 try/except 了。"""
    return JSONResponse(status_code=400, content={"detail": str(exc)})


app.include_router(router)
