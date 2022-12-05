//
//  colors.swift
//  TrueTree
//
//  Created by Jaron Bradley on 12/2/22.
//  Copyright © 2022 mittenmac. All rights reserved.
//

extension String {
 
    var blue: String {
        return "\u{001B}[0;34m\(self)\u{001B}[0;0m"
    }
    
    var magenta: String {
        return "\u{001B}[0;35m\(self)\u{001B}[0;0m"
    }
    
    var cyan: String {
        return "\u{001B}[0;36m\(self)\u{001B}[0;0m"
    }
    
    var red: String {
        return "\u{001B}[0;31m\(self)\u{001B}[0;0m"
    }
}
