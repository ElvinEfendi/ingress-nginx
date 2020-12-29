/*
Copyright 2020 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package settings

import (
	"fmt"
	"net/http"
	"strings"

	"github.com/onsi/ginkgo"
	"k8s.io/ingress-nginx/test/e2e/framework"
)

var _ = framework.DescribeSetting("memcached", func() {
	f := framework.NewDefaultFramework("memcached")
	host := "memcached"

	ginkgo.BeforeEach(func() {
		f.NewEchoDeployment()
	})

	ginkgo.It("generates correct NGINX configuration", func() {
		annotations := make(map[string]string)
		ing := framework.NewSingleIngress(host, "/", host, f.Namespace, framework.EchoService, 80, annotations)
		f.EnsureIngress(ing)

		ginkgo.By("generating correct defaults")

		f.WaitForNginxConfiguration(func(cfg string) bool {
			return strings.Contains(cfg,
				fmt.Sprintf(`memcached = { host = "%v", port = %d, connect_timeout = %d, max_idle_timeout = %d, pool_size = %d }`,
					"", 0, 50, 10000, 50))
		})

		f.HTTPTestClient().GET("/").WithHeader("Host", host).Expect().Status(http.StatusOK)

		ginkgo.By("applying customizations")

		memcachedHost := "memc.default.svc.cluster.local"
		memcachedPort := 11211
		memcachedConnectTimeout := 100
		memcachedMaxIdleTimeout := 5000
		memcachedPoolSize := 100

		f.UpdateNginxConfigMapData("memcached-host", memcachedHost)
		f.UpdateNginxConfigMapData("memcached-port", strconv.Itoa(memcachedPort))
		f.UpdateNginxConfigMapData("memcached-connect-timeout", strconv.Itoa(memcachedConnectTimeout))
		f.UpdateNginxConfigMapData("memcached-max-idle-timeout", strconv.Itoa(memcachedMaxIdleTimeout))
		f.UpdateNginxConfigMapData("memcached-pool-size", strconv.Itoa(memcachedPoolSize))

		f.WaitForNginxConfiguration(func(cfg string) bool {
			return strings.Contains(cfg,
				fmt.Sprintf(`memcached = { host = "%v", port = %d, connect_timeout = %d, max_idle_timeout = %d, pool_size = %d }`,
					memcachedHost, memcachedPort, memcachedConnectTimeout, memcachedMaxIdleTimeout, memcachedPoolSize))
		})

		f.HTTPTestClient().GET("/").WithHeader("Host", host).Expect().Status(http.StatusOK)
	})
})
