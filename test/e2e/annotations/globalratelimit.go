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

package annotations

import (
	"strings"

	"github.com/onsi/ginkgo"

	"k8s.io/ingress-nginx/test/e2e/framework"
)

var _ = framework.DescribeAnnotation("global-rate-limit", func() {
	f := framework.NewDefaultFramework("global-rate-limit-annotation")
	host := "global-rate-limit-annotation"

	ginkgo.BeforeEach(func() {
		f.NewEchoDeployment()
	})

	ginkgo.It("generates correct configuration", func() {
		annotations := make(map[string]string)
		annotations["nginx.ingress.kubernetes.io/global-rate-limit"] = "5"
		annotations["nginx.ingress.kubernetes.io/global-rate-limit-window"] = "2m"

		ing := framework.NewSingleIngress(host, "/", host, f.Namespace, framework.EchoService,
			80, annotations)
		f.EnsureIngress(ing)
		f.WaitForNginxServer(host, func(server string) bool {
			return strings.Contains(server,
				`global_throttle = { namespace = "2dd932d0b48a45ca857eb0124156b717", limit = 5, `+
					`window_size = 120, key = {{nil, nil, "remote_addr", nil, }, } }`)
		})

		ginkgo.By("regenerating the correct configuration after update")
		annotations["nginx.ingress.kubernetes.io/global-rate-key"] = "${remote_addr}${http_x_api_client}"
		ing.SetAnnotations(annotations)
		f.UpdateIngress(ing)
		f.WaitForNginxServer(host, func(server string) bool {
			return strings.Contains(server,
				`global_throttle = { namespace = "2dd932d0b48a45ca857eb0124156b717", limit = 5, `+
					`window_size = 120, `+
					`key = {{nil, "remote_addr", nil, nil, }, {nil, "remote_addr", nil, nil, }, } }`)
		})
	})
})
