import { Hono } from 'hono'

const app = new Hono()

app.get('/', (c) => {
  return c.json({
    app: 'Broka Backend',
    status: 'running'
  })
})

export default app
