//
//  KCOneViewController.swift
//  KcDebugTool_Example
//
//  Created by 张杰 on 2021/12/13.
//  Copyright © 2021 张杰. All rights reserved.
//

import UIKit
import KcDebugTool

class KCOneViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        
        view.backgroundColor = .lightGray
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        didtap()
    }
}

private extension KCOneViewController {
    func didtap() {
        print("点击...")
    }
}
