//
//  AdaptiveMathView.swift
//  Chatmice
//
//  Created by Renat on 24.06.2024.
//

import SwiftUI
import SwiftMath

struct AdaptiveMathView: NSViewRepresentable {
    let equation: String
    let fontSize: CGFloat
    
    func makeNSView(context: Context) -> MTMathUILabel {
        let view = MTMathUILabel()
        view.font = MTFontManager().termesFont(withSize: fontSize)
        view.textColor = .textColor
        view.textAlignment = .left
        view.labelMode = .text
        return view
    }
    
    func updateNSView(_ view: MTMathUILabel, context: Context) {
        if view.latex != equation { view.latex = equation }
        if view.fontSize != fontSize { view.fontSize = fontSize }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTMathUILabel, context: Context) -> CGSize? {
        let size = nsView.fittingSize
        return CGSize(width: ceil(size.width), height: ceil(size.height))
    }
}


