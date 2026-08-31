import { createRouter, createWebHistory } from 'vue-router'

import { storedToken } from './api'
import AccountView from './views/AccountView.vue'
import AccountsView from './views/AccountsView.vue'
import LandingView from './views/LandingView.vue'
import PaymentMethodsView from './views/PaymentMethodsView.vue'

const routes = [
  { path: '/', name: 'landing', component: LandingView },
  { path: '/accounts', name: 'accounts', component: AccountsView, meta: { auth: true } },
  { path: '/accounts/:accountId', name: 'account', component: AccountView, props: true, meta: { auth: true } },
  { path: '/payment-methods', name: 'payment-methods', component: PaymentMethodsView, meta: { auth: true } },
  // Anything else goes home rather than rendering a blank page. CloudFront is
  // configured to serve index.html for unmatched paths, so a deep link that
  // this table does not know about still reaches the router.
  { path: '/:pathMatch(.*)*', redirect: { name: 'landing' } },
]

export const router = createRouter({
  history: createWebHistory(),
  routes,
})

router.beforeEach((to) => {
  if (to.meta.auth && !storedToken()) return { name: 'landing' }
  return true
})
