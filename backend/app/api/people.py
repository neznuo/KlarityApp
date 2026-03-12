"""People CRUD endpoints."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db.database import get_db
from app.models.person import Person
from app.schemas import PersonCreate, PersonOut, PersonUpdate

router = APIRouter(prefix="/people", tags=["people"])


@router.get("", response_model=list[PersonOut])
def list_people(db: Session = Depends(get_db)):
    return db.query(Person).order_by(Person.display_name).all()


@router.post("", response_model=PersonOut, status_code=201)
def create_person(body: PersonCreate, db: Session = Depends(get_db)):
    person = Person(**body.model_dump())
    db.add(person)
    db.commit()
    db.refresh(person)
    return person


@router.patch("/{person_id}", response_model=PersonOut)
def update_person(person_id: str, body: PersonUpdate, db: Session = Depends(get_db)):
    person = db.get(Person, person_id)
    if not person:
        raise HTTPException(status_code=404, detail="Person not found")
    for key, value in body.model_dump(exclude_none=True).items():
        setattr(person, key, value)
    db.commit()
    db.refresh(person)
    return person


@router.delete("/{person_id}", status_code=204)
def delete_person(person_id: str, db: Session = Depends(get_db)):
    person = db.get(Person, person_id)
    if not person:
        raise HTTPException(status_code=404, detail="Person not found")
    db.delete(person)
    db.commit()
