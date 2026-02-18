# Data Models & API Contracts

## Entities
<!-- One section per entity. Define every field. -->

### [Entity Name]

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| id | string (uuid) | yes | Unique identifier |
| ... | ... | ... | ... |

**Relationships:**
- [Describe relationships to other entities]

### [Entity Name]

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| ... | ... | ... | ... |

---

## API Endpoints
<!-- One section per endpoint. Define method, path, auth, request, response, errors. -->

### [Endpoint Name]

- **Method**: GET / POST / PUT / DELETE
- **Path**: /api/...
- **Auth**: required / public
- **Request body**:
```json
{}
```
- **Response**:
```json
{}
```
- **Error states**:
  - 400: [When / why]
  - 401: [When / why]
  - 404: [When / why]

---

## State Management
<!-- How is client-side state managed? What are the key state shapes? -->

- **Approach**: [Context API / Zustand / Redux / server state only / etc.]
- **Key state shapes**:
  - [State 1]: [What it holds, where it's used]
  - [State 2]: [What it holds, where it's used]
